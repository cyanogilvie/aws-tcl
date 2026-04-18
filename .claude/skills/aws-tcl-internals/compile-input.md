# compile_input — the central shape walk

`aws::build::compile_input` (in aws.tcl, ~line 3408) is the pivot point for
request serialization. It walks a shape tree and produces:

- A `template_obj` — an rl_json template with `~S:`/`~N:`/`~B:`/`~J:`
  substitution markers for each body member
- A flat list of `-params` argspec entries for `parse_args`
- Parallel lists for URI / header / query-string / body-payload routing
- A list of `transforms` — per-member runtime value conversions (see
  `transforms-and-rewriter.md`)
- Builtins / endpoint-rules context wiring

It is called *recursively* for nested members. The top-level call (no
`-argname`) unfolds the input structure into parse_args-visible
parameters. Recursive calls (with `-argname`) short-circuit for
composite shapes — they emit `~J:argname` and let the user pass the
nested value as a JSON fragment (see `protocols.md` for why).

## The short-circuit, in detail

```tcl
structure - union {
    if {[info exists argname]} {
        set rspec [build_rewriter_spec $shapes $shape $protocol]
        if {$rspec ne ""} {
            lappend transforms [list rewrite $argname $rspec]
            return [json string "~J:_tx_$argname"]
        }
        return [json string "~J:$argname"]
    }
    # top-level: iterate members and recurse
}
```

When a nested shape has any transformation requirement (blob inside,
jsonName renames, timestamp normalisation, etc.), we generate a
rewriter spec and register a `rewrite` transform — the body template
then substitutes the *transformed* value (`~J:_tx_argname`) instead of
the raw user-supplied JSON fragment (`~J:argname`).

List and map members go through the same path (see the `map - list`
branch). Pass-through (no rewriter needed) is the common case and has
zero runtime overhead.

## Output aliases (parse_args `-alias`)

Callers pass named variables to be populated:

| alias | Contents | Consumer |
|---|---|---|
| `-params` | flat list `{-argname argspec -argname argspec ...}` | parse_args call in the generated op body |
| `-uri_map` | `{pattern argname ...}` | runtime URI template substitution |
| `-query_map` | for query/ec2: triples `{serialized_name argname spec}`; for rest-*: pairs for `location: querystring` members | `_flatten_query_param` / query-string build |
| `-header_map` | `{header_name argname ...}` (name may end in `*` for `location: headers` wildcards) | runtime header construction |
| `-payload` | name of the member with `payload: true` attribute, or empty | `_service_req` body-selection branch |
| `-transforms` | list of `{kind argname ?extra?}` | op body prep lines before template apply |
| `-builtins` | `{argname builtin_source ...}` | `::aws::_builtins` call to fill endpoint-rules context |
| `-copy_to_cx` | `{argname cx_name ...}` | `_copy2cx` to transfer parse_args values to endpoint-rules context |
| `-cx_suppress` | dict of camel names to suppress from cxparams | endpoint-rules context assembly |
| `-cxparams` | the endpoint-rules parameter definitions (preserved for later use) | |

The return value is the `template_obj` string (JSON template). The
caller writes this into the op body so that at runtime
`json template $template_obj` produces the body.

## argname_transform

By default, member camel names are converted to snake_case Tcl arg
names via `aws::from_camel`. The rest-xml lazy-compile path passes
`-argname_transform {}` so that camel names pass through unchanged —
this is a deliberate difference because the rest-xml path handles
member mapping differently at runtime.

**Every name derivation inside `compile_input` must honour
`argname_transform`**, including the `payload` lookup at the top of
the proc (`set payload [... [json get $input payload]]`). A bug where
`payload` unconditionally called `aws from_camel` silently broke
rest-xml body uploads (PascalCase `Body` parse_args local vs.
snake-case `body` passed as `-b` to `_service_req`), producing empty
bodies and `"You must provide the Content-Length HTTP header."`
errors from S3. Fixed in `aws.tcl:3786`.

## aws::from_camel — digit-sensitive

The function preserves the case of acronym runs and lowercases only
word-words. Crucially, **it handles digit suffixes on both**:

- `fooEnum1` → `foo_enum1`
- `UseFIPS` → `use_FIPS`
- `S3Bucket` → `S3_bucket`
- `IPV4Address` → `IPV4_address`
- `DBInstanceIdentifier` → `DB_instance_identifier`

A pre-fix version silently stripped trailing digits (`fooEnum1` →
`foo_enum`), which collided members and made several services' ops
unreachable. If you touch the regex, test against all of those.

## Location routing (top-level members)

Before recursing into a member's shape, compile_input checks for a
`location` attribute:

```tcl
if {[json exists $member_def location]} {
    switch -- [json get $member_def location] {
        uri         { lappend uri_map    $locationName $name }
        querystring { lappend query_map  $locationName $name {} }
        headers     { lappend header_map $locationName* $name }
        header      { lappend header_map $locationName  $name }
    }
} elseif {$protocol in {json rest-json rest-xml}} {
    # body member: recurse and build template fragment
} elseif {$protocol in {query ec2}} {
    # body member: add to query_map with a shape-driven flatten spec
}
```

Note that for query/ec2, there is no body template — everything goes
through `query_map` with a flatten spec produced by
`compile_query_spec`.

## Endpoint params / cxparams

After the members are processed, compile_input walks the endpoint-rule
parameter definitions (`$endpoint_params`) and adds corresponding
`-params` entries and `-builtins` / `-copy_to_cx` bindings so that
values like `-region`, `-use_FIPS`, `-endpoint` can be supplied by the
caller and flow into the endpoint-rules context.

Operations whose input shape doesn't already bind region get one added
explicitly so every call accepts `-region`.

## Top-level structure handling

When there's no `argname`:

```tcl
structure - union {
    set template_obj {{}}
    json foreach {camel_name member_def} [json extract $input members] {
        set name [aws::from_camel $camel_name]
        # build argspec, handle location, recurse if body member
        json set template_obj $locationName [compile_input ... -argname $name ...]
    }
}
```

The locationName default is the *camel* name (not the snake arg name).
The `template_obj` key is the wire name; the `~S:argname` substitution
inside uses the snake name.

## Recursion with the rewriter

If a body member is itself a structure / list / map, the recursive
call returns `~J:argname` (or `~J:_tx_argname` with a rewriter). The
parent's template_obj ends up looking like:

```json
{
    "WireName":      "~S:snake_arg_for_scalar",
    "NestedWire":    "~J:_tx_nested_arg_name"
}
```

At runtime the snake_arg's value goes in as a scalar, and the nested
arg's JSON fragment goes in verbatim (post-transform).
