# Shape types and member attributes

Botocore's `service-2.json` describes every request / response shape.
This page lists every attribute we rely on, because many are non-obvious
and multiple attribute pairs mean similar things in different protocols.

## Shape types

| type | Notes |
|---|---|
| `string` | plain string; may have `enum` list, `sensitive`, `pattern`, `min`, `max` |
| `integer` / `long` | serialized as JSON number or query string |
| `float` / `double` | NaN/Infinity special-cased for JSON bodies (see transforms) |
| `boolean` | JSON `true`/`false`; query `true`/`false` (not `1`/`0`) |
| `timestamp` | `timestampFormat` attr picks iso8601 / unixTimestamp / rfc822 |
| `blob` | bytes; base64 in body, or raw payload for streaming |
| `structure` | object with named `members`. The `document: true` flag means "accept any JSON" |
| `union` | like structure but exactly one member present; treated the same way we treat structure |
| `list` | ordered; `member.shape` is element shape; `flattened` affects wire form |
| `map` | `key.shape` and `value.shape`; `flattened` affects wire form |

`resolve_shape_type` in aws.tcl chases `shape`-only references until it
finds a `type`. Don't look at `[json get $shapes $name type]` directly.

## Member attributes (inside a structure's `members`)

These attributes are on the *reference* in the parent, not on the
target shape:

| attribute | Purpose |
|---|---|
| `shape` | target shape name |
| `locationName` | wire name override (XML tag, query param prefix, etc.) |
| `jsonName` | JSON body key override (json/rest-json) — distinct from `locationName` |
| `queryName` | ec2-protocol wire name override (takes precedence over first-letter-uppercased `locationName`) |
| `location` | `header` / `headers` / `uri` / `querystring` (absent = body) |
| `flattened` | on a list/map: no `.member.`/`.entry.` infix; elements inline under the member's own name |
| `required` | validation hint; we honour it via parse_args `-required` |
| `contextParam` | binds this member's value into the endpoint-rules context |
| `builtIn` | endpoint-rules built-in source (e.g. `AWS::Region`, `AWS::UseFIPS`) |
| `timestampFormat` | overrides the shape-level timestampFormat |
| `hostLabel` | this value fills a `{label}` slot in the operation's `endpoint.hostPrefix` |
| `eventpayload` | (event streams — not supported yet) |
| `xmlNamespace` | rest-xml namespace on the element |
| `xmlAttribute` | this member is an XML attribute, not a child element |
| `sensitive`, `deprecated`, `documentation` | informational |

Shape-level attributes:

| attribute | Purpose |
|---|---|
| `payload` | (on structure) the body is just this member's value, not the wrapping struct |
| `flattened` | (on list/map) shape-level variant of the member-level flag; honour either |
| `document` | (on structure) this is a Document type: accept any JSON value |
| `enum` | (on string) enumeration of valid values |
| `error` | (on structure) this shape is an error type; has `code`, `httpStatusCode`, `senderFault` |
| `streaming` | (on blob) body is streamed, not loaded |
| `timestampFormat` | (on timestamp) default format for this timestamp shape |

## locationName vs jsonName vs queryName

Classic confusion. All three are wire-name overrides, but they apply to
different protocols. Priority at compile time:

- **JSON body key**: `jsonName` if present, else `locationName` if present,
  else the camelCase member name.
- **Query param prefix (query protocol)**: `locationName` if present,
  else the member name. `queryName` is *not* used.
- **Query param prefix (ec2 protocol)**: `queryName` if present, else
  `locationName`-with-first-letter-uppercased, else
  memberName-with-first-letter-uppercased.
- **rest-xml element name**: `locationName`, else member name.
- **URI path placeholder, header name, query-string name**: `locationName`
  (there's no equivalent jsonName/queryName — the location overrides take
  over).

The rewriter (`build_rewriter_spec`) currently consults `jsonName` then
`locationName` when building the JSON-body key map for nested members.
Don't rename it without checking both query and ec2 paths.

## Non-body locations

Members with `location: header`, `location: uri`, `location: querystring`
don't participate in body assembly. `compile_input` routes them into
`header_map`, `uri_map`, and `query_map` aliases, *not* into the
template_obj. `build_rewriter_spec` must skip them too (there's an
explicit `[json exists $mdef location] continue` guard) or you'll end up
trying to rewrite a header inside the body rewriter.

## Flattened semantics, precisely

For a list `Stacks` (shape `StackList`), the four combinations are:

|                                    | member has locationName="X" | no locationName |
|---|---|---|
| `flattened: true` on shape/member  | elements at `$parent/X`     | elements at `$parent` (repeated) |
| not flattened                      | elements at `$parent/X`     | elements at `$parent/member`    |

The `member` default for the non-flattened, no-locationName case is
where the cloudformation `list_stacks` regression lived before the fix;
always test the four combinations separately if you refactor this.

## Shape-level defaults worth knowing

- Query/ec2/rest-xml timestamps default to iso8601; json/rest-json
  default to unixTimestamp (epoch integer). Shape `timestampFormat`
  overrides the default.
- For headers, timestamps default to rfc822.
- Blob members default to base64 encoding in JSON bodies; raw bytes
  when they're the payload member (entire body).
- Boolean wire form is the JSON primitive `true`/`false`, not `1`/`0` —
  _tx_rewrite's float branch is specifically for *non-finite* numbers,
  not booleans.
