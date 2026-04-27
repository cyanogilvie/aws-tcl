# Spec: `-cafile` / `-cadir` support in rl_http (and s2n)

## Motivation

aws-tcl is closing the gap with the AWS CLI's credential/config resolution,
and `AWS_CA_BUNDLE` (plus the `ca_bundle` config-file key) is one of the
standard CLI knobs. Both select a PEM bundle of trust roots for TLS
verification. Corporate MITM-proxied environments and air-gapped setups
rely on this.

Today rl_http hardcodes `tls::import … -require true -cadir /etc/ssl/certs`
(`rl_http.tcl:656,658`) and s2n's `push_tls` uses whatever trust store the
s2n config object was built with — no per-call override. Callers cannot
supply a custom CA bundle.

## Scope

Work spans two packages:

1. **rl_http** — surface `-cafile` / `-cadir` (and a generic `-s2n_config`
   dict escape-hatch); thread them through `push_tls` into whichever TLS
   driver is active; partition the keepalive pool on TLS-identity so
   parked connections are only reused when their handshake parameters
   match.
2. **s2n** (the Tcl wrapper) — add trust-store config keys so rl_http can
   pass them in. The underlying s2n-tls C API already supports this
   (`s2n_config_set_verification_ca_location`).

The `tls` driver path needs no upstream work beyond rl_http — `tls::import`
already accepts `-cafile` / `-cadir`. s2n needs the wrapper addition.

## s2n (the Tcl package) changes

The existing config-dict parser in `get_s2n_config_from_obj` (`generic/s2n.c`
around line 851) currently accepts the dict keys `session_tickets`,
`ticket_lifetime`, `cipher_preferences`. Extend it with:

- `ca_file <path>` — PEM bundle of trusted CAs
- `ca_dir <path>`  — directory of hashed PEM certs (OpenSSL style)

Both map onto `s2n_config_set_verification_ca_location(cfg, ca_file, ca_dir)`.
The s2n C API takes both as a single call accepting either NULL; the Tcl
parser must therefore buffer whichever keys it sees in the dict and call
`s2n_config_set_verification_ca_location` once after the dict walk, not
inside the per-key switch, so a dict that sets only `ca_dir` doesn't
clobber an earlier `ca_file` (and vice-versa).

Semantics note: by default `s2n_config_new()` loads system certificates,
and `s2n_config_set_verification_ca_location` *adds* to that set (per the
s2n-tls API docs in `api/s2n.h:850-868`). To match AWS CLI `AWS_CA_BUNDLE`
semantics — custom bundle wholly replaces system roots — the wrapper
must call `s2n_config_wipe_trust_store(cfg)` before
`s2n_config_set_verification_ca_location` when either of the new dict
keys is present. Document this in the Tcl wrapper.

No changes to `push_cmd`'s option surface. Callers pass trust config via
`-config [list ca_file $path]` (which accepts a bare dict); the intrep
cache on the config Tcl_Obj handles reuse.

**Lifetime fix (incidental)**: the existing `push_cmd` / `socket_cmd`
took a pointer to the `s2n_config` C struct without any independent
refcount on it (flagged in the source as a TODO). That was latent until
now — most callers kept a live Tcl_Obj around — but rl_http builds the
config dict inline from per-request `$settings` and drops it on instance
destroy, so a parked keepalive channel ended up pointing at a freed
config (observed as `S2N_ERR_UNSUPPORTED_WITH_QUIC` from `s2n_recv`
when the parked channel is resumed).

An initial fix retained the config Tcl_Obj directly via `replace_tclobj`
in `con_cx`, but that only guards against the Tcl_Obj being *freed*, not
against it shimmering to another type (a `dict size $config` call elsewhere
in the script would free the s2n_config intrep while the Tcl_Obj survived).
The final shape introduces an explicit C-level refcount wrapper:

```c
struct s2n_config_rc {
    Tcl_Size            refCount;
    struct s2n_config*  c;
};
```

- `get_s2n_config_from_obj` builds an `s2n_config_rc`, stores a
  reference in the Tcl_Obj intrep (refCount=1), and returns the rc.
- `OPT_CONFIG` in `push_cmd` / `socket_cmd` stashes the rc in
  `con_cx->config` and bumps `refCount++`.
- `free_s2n_config_intrep` decrements; on Tcl_Obj shimmer its ref goes
  away but the connection's does not.
- `free_con_cx` decrements. When the last ref drops, `s2n_config_free`
  runs and the wrapper is `ckfree`d.

This gives connection lifetime that is strictly independent of any
Tcl_Obj identity: scripts can freely shimmer, unset, or construct
equivalent dicts without disturbing in-flight TLS state.

Regression coverage: `tests/push.test` has three `push-config-shimmer-*`
tests — dict/list shimmer on a live connection, and keepalive-style
reuse of a shared, shimmered config — each of which segfaults without
the wrapper.

### s2n tests

Negative test: pass `-config [list ca_file /nonexistent/bundle.pem]` to
`s2n::push` against a real TLS host, assert the handshake fails. The
positive test (bundle that *does* contain the host's roots) requires
either a bundled test CA or trusting that the negative case failing
means the option is wired up — the negative test alone is acceptable
signal.

## rl_http changes

### New constructor options

```tcl
-cafile      {-default ""}  ;# Path to a PEM bundle of trusted CAs.
                            ;# Empty = driver default.
-cadir       {-default ""}  ;# Directory of hashed PEM certs (OpenSSL style).
                            ;# Empty = driver default.
-s2n_config  {-default ""}  ;# Generic s2n config dict (escape hatch for
                            ;# options beyond ca_file/ca_dir). Keys listed
                            ;# in s2n's get_s2n_config_from_obj. Merged
                            ;# with -cafile/-cadir shortcuts — shortcuts
                            ;# win on conflict with ca_file/ca_dir keys.
```

When `-cafile` / `-cadir` are both empty and `-s2n_config` is empty, the
tls driver retains its legacy `-cadir /etc/ssl/certs` default. When any
of these are set, the driver uses the supplied values and does *not*
apply the hardcoded `/etc/ssl/certs`.

### `push_tls` changes

Keep the signature `method push_tls {chan servername}` — the method
already runs in the instance context and has `$settings` access. Read
the three new keys from `$settings` inside the method. This avoids
touching the two call-sites at `:562` and `:606`.

```tcl
method push_tls {chan servername} {
    variable ::rl_http::tls_driver
    set cafile      [dict getdef $settings cafile ""]
    set cadir       [dict getdef $settings cadir ""]
    set s2n_config  [dict getdef $settings s2n_config {}]
    if {$cafile ne ""} { dict set s2n_config ca_file $cafile }
    if {$cadir  ne ""} { dict set s2n_config ca_dir  $cadir }

    if {$::rl_http::tls_driver eq "s2n"} {
        package require s2n
        set opts [list -prefer throughput]
        if {$servername ne ""}           { lappend opts -servername $servername }
        if {[dict size $s2n_config] > 0} { lappend opts -config $s2n_config }
        s2n::push $chan {*}$opts
    } else {
        package require tls
        set opts [list -require true]
        if {$servername ne ""} { lappend opts -servername $servername }
        if {$cafile ne "" || $cadir ne ""} {
            if {$cafile ne ""} { lappend opts -cafile $cafile }
            if {$cadir  ne ""} { lappend opts -cadir  $cadir }
        } else {
            lappend opts -cadir /etc/ssl/certs
        }
        tls::import $chan {*}$opts
    }
}
```

Non-`ca_file` / `ca_dir` keys in `-s2n_config` are silently ignored by
the tls driver branch — the generic dict is an s2n-specific escape hatch
and the tls driver is only asked to honor what it understands.

### Keepalive pool partitioning

Today the pool key is `$scheme://$host:$port` (`rl_http.tcl:502`, `:696`).
TLS parameters are negotiated *once*, at park time, and baked into the
channel. Without partitioning, a channel whose handshake was validated
against `/etc/ssl/certs` could be handed to a caller asking for
`-cafile /corp/bundle.pem`, silently failing to honour the stated trust
posture. (It *also* fixes a pre-existing latent bug: differing SNI values
on the same `host:port` currently share the pool.)

The pool key is extended with a canonical query-param suffix carrying
every parameter that participates in the TLS handshake. Construction
uses `reuri` (already an optional rl_http dep; the existing check at
`:21` gates on `reuri 0.15`):

```tcl
method _keepalive_key {scheme host port} {
    set key $scheme://$host:$port
    if {$scheme ne "https"} { return $key }     ;# http: no TLS, no partition needed

    set cafile      [dict getdef $settings cafile ""]
    set cadir       [dict getdef $settings cadir ""]
    set s2n_config  [dict getdef $settings s2n_config {}]
    if {$cafile ne ""} { dict set s2n_config ca_file $cafile }
    if {$cadir  ne ""} { dict set s2n_config ca_dir  $cadir }
    set sni [dict getdef $settings override_host ""]

    # Canonicalize dict ordering so two callers passing the same dict
    # with differently-ordered keys hash to the same pool slot.
    foreach {k v} [lsort -stride 2 -index 0 $s2n_config] {
        reuri query add key s2n_$k $v
    }
    if {$sni ne "" && $sni ne $host} {
        reuri query set key sni $sni
    }
    reuri normalize key
}
```

Conventions:

- **Prefix discipline.** Query params derived from the forwarded s2n
  config dict are prefixed `s2n_`; rl_http's own partition inputs live
  in the unprefixed space (currently only `sni`). This puts
  namespace-deconfliction in rl_http's hands — rl_http can add new
  partition-affecting options without caring what key names s2n adds
  in future.
- **Canonical dict ordering.** `lsort -stride 2 -index 0` sorts the
  dict by key before serialization; without this, equivalent dicts
  passed in different orders would fragment the pool.
- **Numeric port.** The key must use the resolved numeric port (as
  today, `$u(port)`) — `reuri normalize` does not strip scheme-default
  ports, so `https://host/` and `https://host:443/` would otherwise
  key differently.
- **reuri is required** when any of these options are set. If the
  constructor sees a non-empty `-cafile`, `-cadir`, or `-s2n_config`
  and reuri isn't available, raise a clear error. For the no-option
  fast path, behaviour is unchanged — no reuri dependency, no extra
  work in `_keepalive_key`.
- **http scheme short-circuits.** No TLS parameters apply, so the
  partition suffix is always empty; skip the work.

Both `_keepalive_connect` and `_keepalive_park` call `_keepalive_key`
rather than constructing the key inline.

### Caller call-sites

`push_tls` is called at `rl_http.tcl:562` and `:606`; neither needs to
change — the method reads from `$settings`. `_keepalive_park` is called
at `:477`; it will call `_keepalive_key` internally, so no change at
the caller.

### Version bump

Bump rl_http to 1.24 (the `Makefile` is already at `VER=1.23` in-flight;
1.22 is the last tagged `.tm` artifact). aws-tcl's `CLAUDE.md` floor
`rl_http ≥ 1.23` becomes `≥ 1.24`.

### rl_http tests

- Negative handshake: `-cafile /nonexistent/bundle.pem` against a real
  https host fails with a handshake error. Gated on the s2n driver being
  active (where the new plumbing is most exercised) and on network
  access.
- Pool partition (whitebox): call `_keepalive_key` directly with
  varying settings and assert distinct keys for distinct TLS inputs,
  identical keys when dict key-order differs.

## How aws-tcl will consume this

Once rl_http ships, aws-tcl's rl_http call-sites gain
`-cafile $::aws::ca_bundle` (empty when unset), where `$::aws::ca_bundle`
is resolved from `AWS_CA_BUNDLE` env → config-file `ca_bundle` key →
empty. Bump the rl_http version floor in aws-tcl's Makefile / CLAUDE.md.

## Non-goals

- No API for in-memory PEM strings. aws-tcl only needs file-path support
  to honor `AWS_CA_BUNDLE`.
- No cert pinning, no custom verification callbacks, no OCSP toggling.
- No change to the `tls_driver` selection logic (still process-wide).
- No per-instance override of the tls driver — rl_http has never
  supported this and isn't starting now.

## Sequencing

s2n changes land first (they're a pure feature-add in s2n). rl_http's
s2n-driver branch simply relies on s2n accepting `ca_file` / `ca_dir`
dict keys; if rl_http 1.24 were used against an older s2n, the push
call would raise a parse error from `get_s2n_config_from_obj` — an
acceptable failure mode (clear message, easy to diagnose, no silent
trust-store fall-back).
