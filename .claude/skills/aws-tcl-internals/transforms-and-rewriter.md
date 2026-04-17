# Transforms and the rewriter

Two layers of per-value transformation run on body values between the
user's argument and the wire form: **scalar transforms** (blob, float,
timestamp) and the **rewriter** (recursively walking nested JSON
fragments).

## Runtime entry point

`aws::_apply_tx kind var ?extra?` is called from the generated op body
*before* `json template` evaluates. For each registered transform it
reads the source var, computes the transformed value, and writes it into
a parallel `_tx_<var>` var in the caller's scope. The body template
references `~{S,J,N}:_tx_<var>` instead of `~{S,J,N}:<var>`.

```tcl
proc _apply_tx {kind var args} {
    upvar 1 $var src _tx_$var dst
    if {![info exists src]} return
    set dst [switch -exact -- $kind {
        blob      { _tx_blob $src }
        float     { _tx_float $src }
        ts_epoch  { _tx_ts_epoch $src }
        ts_iso    { _tx_ts_iso $src }
        ts_rfc822 { _tx_ts_rfc822 $src }
        rewrite   { _tx_rewrite $src [lindex $args 0] }
    }]
}
```

Because the `_tx_<var>` var is only set if `src` was set, an unset
source still resolves to JSON null in the template, letting the null-
stripping pass drop it.

## Scalar transforms

All take a Tcl scalar in and return a Tcl value that the template
substitutes literally:

| Kind | In | Out | Used for |
|---|---|---|---|
| blob | raw bytes | base64 string | body blobs: `~S:_tx_X` |
| float | number or `NaN`/`Infinity`/`-Infinity` | bare number or `json string "NaN"` etc. | JSON float/double bodies: `~J:_tx_X` |
| ts_epoch | epoch int or ISO 8601 | epoch int | json/rest-json timestamps: `~N:_tx_X` |
| ts_iso | epoch int or ISO 8601 | ISO 8601 string | query/ec2/rest-xml timestamps: `~S:_tx_X` |
| ts_rfc822 | epoch int or ISO 8601 | RFC 822 string | header timestamps: `~S:_tx_X` |

`_tx_ts_parse` normalises either an integer-looking Tcl value or an ISO
8601 string into epoch seconds; the three timestamp transforms all go
through it.

Notice that `float` uses `~J:` (JSON fragment), not `~N:` — that's so
the transform can return either a bare number (for normal values) or a
quoted string (for NaN/Infinity), and both are valid JSON fragments.

## The rewriter

For nested structure/union/list/map members that contain anything
needing transformation, `build_rewriter_spec` (compile time) produces a
recursive spec, and `_tx_rewrite` (runtime) walks the user's JSON
fragment per the spec, emitting a transformed JSON fragment.

### Spec grammar

```
spec ::= ""                                (identity — common, cheap)
       | blob
       | float
       | {ts FMT}                          FMT = iso8601 | unixTimestamp | rfc822
       | {struct {ckey loc subspec ...}}   object: rename ckey→loc, recurse
       | {list subspec}                    array: recurse per element
       | {map subspec}                     object-as-map: recurse per value, keys pass through
```

`ckey` is the member's camelCase name as it appears in the user's JSON;
`loc` is the wire-form name (`jsonName` > `locationName` > `ckey`).

### Identity optimisation

`build_rewriter_spec` returns `""` whenever the entire subtree is
pass-through — no transforms, no renames. The vast majority of real
shapes hit this path and therefore register *no* rewriter and pay *no*
runtime cost. The `has_changes` boolean in the `structure - union`
branch tracks whether any member has `loc ne ckey` or a non-empty
subspec.

Document types (`document: true` on the shape) are forced to identity
because they accept arbitrary JSON.

### Recursion depth guard

`build_rewriter_spec` has a `seen` list and truncates at depth 5 for
any given shape, to handle recursive shapes like
`StructArg{RecursiveArg: StructArg}`. Five levels cover every real
service we've seen; beyond that the value passes through opaquely.

### Shape walk specifics

- `location: header/uri/querystring` members are skipped — they aren't
  in the body.
- For structures and unions, member name priority for `loc` is
  `jsonName` > `locationName` > `ckey` (same priority as compile_input).
- For lists, the element's `locationName` is *not* used in the spec —
  the rewriter only touches values, not array element names (which JSON
  doesn't have).
- For maps, the key subspec is always `string` (map keys are always
  strings in AWS shapes), so we only carry a value subspec in the spec.

## Where transforms get registered

In `compile_input`:

- `blob` shape branch → `{blob $argname}` + `~S:_tx_$argname`
- `float` / `double` branch → `{float $argname}` + `~J:_tx_$argname`
- `timestamp` branch → one of `{ts_epoch $argname}` / `{ts_iso $argname}`
  / `{ts_rfc822 $argname}` depending on `timestampFormat` + protocol
  default
- `structure` / `union` with argname → `build_rewriter_spec` → if
  non-empty, `{rewrite $argname $spec}` + `~J:_tx_$argname`
- `list` / `map` branches → same rewriter path

In `build.tcl`, after `compile_input`, transforms are injected into
`static` (the op-body prep lines) via:

```tcl
foreach tfm $transforms {
    lassign $tfm kind var
    lappend static [list ::aws::_apply_tx $kind $var]
}
```

(For rewrite, the spec is also captured — `_apply_tx` takes it via
its trailing `args`.)

## Extending with a new transform kind

1. Add a `_tx_foo` helper in aws.tcl that takes a value and returns
   the transformed form.
2. Add a branch to `_apply_tx`'s switch.
3. Emit `lappend transforms [list foo $argname]` in the relevant
   compile_input branch (and/or in `build_rewriter_spec` if the
   transform should apply to nested values).
4. If the rewriter needs to know about it, add a corresponding branch
   to `_tx_rewrite`'s switch.

## Common mistakes and sharp edges

- Don't forget to update *both* the rewriter (which walks JSON) *and*
  the scalar transform (which takes Tcl input). They have different
  input contracts even though they handle the same shape kind.
- Rewriter input is always JSON; scalar-transform input is always Tcl.
  The test harness (`protocol_vectors.test`) has a `tx_kind` lookup
  that picks the right form per var — that has to stay aligned with
  the real runtime. If you add a new transform kind that takes JSON in,
  update `wants_json` in `assemble_json_body`.
- `_apply_tx` stores into `_tx_<var>` — don't use that prefix in your
  own template substitutions or names will collide.
- For Document types the rewriter returns `""` (identity). If you add a
  non-identity transform for Documents, the `document: true` short-
  circuit in `build_rewriter_spec` needs updating.
