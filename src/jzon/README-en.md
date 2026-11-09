# jzon

JSON and ZON in both directions, written in pure Zig, standard library only.

- One pair of calls per format: `serialize` turns a typed value into text, `deserialize` turns text back into a typed value.
  - JSON: `jzon.json.serialize`, `jzon.json.deserialize`.
  - ZON: `jzon.zon.serialize`, `jzon.zon.deserialize`.
- JSON has four write paths and four read paths. Every one of them produces the same bytes and reads the same documents, so picking one is a cost decision and never a correctness one.
- ZON has one write path and one read path, generated from the type. It covers the shape `build.zig.zon` uses.
- Serialize allocates nothing. The caller hands over a buffer, and a value that does not fit is a `NoSpaceLeft` error.
- Deserialize allocates only what the result points at, out of the allocator handed in, so an arena reset frees a whole parse in one step.
- Strings can be borrowed from the document instead of copied.
- A field type a generated path has no form for is a compile error naming the type, never a runtime failure.
- Builds on Zig 0.17.

For the architecture see `docs/hld-en.md`, for the internals see `docs/lld-en.md`, for measured cost see `docs/benchmark-en.md`.

## Import

jzon ships inside zix and is reachable from it:

```zig
const zix = @import("zix");

const len = try zix.jzon.json.serialize(&buf, order, .{});
```

It is also a standalone package under `src/jzon` with its own build files, so it can be depended on by itself. Add it as a path dependency in your `build.zig.zon`:

```zig
.dependencies = .{
    .jzon = .{ .path = "path/to/jzon" },
},
```

Wire the module in `build.zig`:

```zig
const jzon = b.dependency("jzon", .{}).module("jzon");
exe.root_module.addImport("jzon", jzon);
```

## Quickstart

One record carries both directions and both formats:

```zig
const Status = enum { PENDING, SHIPPED, CANCELLED };

const Line = struct {
    sku: []const u8,
    qty: u32,
    price_cents: i64,
};

const Order = struct {
    id: u64,
    customer: []const u8,
    status: Status,
    note: ?[]const u8 = null,
    tags: []const []const u8,
    lines: []const Line,
};
```

### A value into text

```zig
var buf: [1024]u8 = undefined;

const json_len = try jzon.json.serialize(&buf, order, .{});
const zon_len = try jzon.zon.serialize(&buf, order, .{});
```

The buffer belongs to the caller, so a handler can render straight into the send buffer an engine hands it. Nothing is allocated, and the only failure is a full buffer.

### Text back into a value

```zig
const from_json = try jzon.json.deserialize(Order, arena.allocator(), json_text, .{});
const from_zon = try jzon.zon.deserialize(Order, arena.allocator(), zon_text, .{});
```

Everything the result points at comes from that allocator. An arena is the natural fit for a server: parse the request body into it, answer, reset it.

### Files

jzon reads and writes slices, not files. The caller reads the file once, then hands the slice over:

```zig
const cwd = std.Io.Dir.cwd();

const text = try cwd.readFileAlloc(io, "order.zon", allocator, .limited(1 << 16));
const order = try jzon.zon.deserialize(Order, allocator, text, .{});

const len = try jzon.zon.serialize(&buf, order, .{});
try cwd.writeFile(io, .{ .sub_path = "order.zon", .data = buf[0..len] });
```

The written text ends at the closing `}` with no line feed. Add one when the file should end with it.

### The third parameter

The last parameter is an options struct. `.{}` means every field at its default, so only the fields that change are named:

```zig
const len = try jzon.json.serialize(&buf, order, .{ .strategy = .GENERATED });

const parsed = try jzon.json.deserialize(Order, arena.allocator(), body, .{
    .strategy = .GENERATED,
    .strings = .BORROW,
    .unknown = .SKIP,
});

const compact = try jzon.zon.serialize(&buf, order, .{ .layout = .COMPACT });

const package_text = try jzon.zon.serialize(&buf, package, .{
    .hex_fields = &.{"fingerprint"},
});
```

The options are comptime, so only the path named is compiled into the binary.

## JSON write strategies

| Strategy | What it runs |
| :- | :- |
| `.STD` | `std.json.Stringify`, which renders every shape std renders |
| `.GENERATED_FMT` | generated from the type, integers through `std.fmt` |
| `.GENERATED` | generated from the type, integer digits written straight into the buffer |
| `.GENERATED_VECTOR` | as `.GENERATED`, with strings scanned one vector lane at a time |

## JSON read strategies

| Strategy | What it runs |
| :- | :- |
| `.STD` | `std.json` reflection, which parses every shape std parses |
| `.SCANNER` | tokens from `std.json.Scanner`, with the field dispatch generated from the type |
| `.GENERATED` | generated from the type, over jzon's own read cursor, one byte at a time |
| `.GENERATED_VECTOR` | as `.GENERATED`, one vector lane at a time |

`.GENERATED_VECTOR` is not always the quickest, on either side. It pays on long strings and costs on short ones, which is why the width stays a call-site choice rather than a default. See `docs/benchmark-en.md` for what it measures on one record.

## Options

`jzon.json.SerializeOptions`:

| Field | Default | What it decides |
| :- | :- | :- |
| `strategy` | `.STD` | which write path runs |

`jzon.json.DeserializeOptions`:

| Field | Default | What it decides |
| :- | :- | :- |
| `strategy` | `.STD` | which read path runs |
| `strings` | `.COPY` | `.COPY` copies every string into the allocator, `.BORROW` points a string with no escape at the document, which then has to outlive the value |
| `unknown` | `.REJECT` | `.REJECT` fails on a key the type does not declare, `.SKIP` steps over the key and its whole value however deep it nests |

`jzon.zon.ZonOptions` (one struct for both directions):

| Field | Default | Read by | What it decides |
| :- | :- | :- | :- |
| `strings` | `.COPY` | deserialize | same as JSON. A one-line `\\` string with no `\r` can be borrowed too |
| `unknown` | `.REJECT` | deserialize | same as JSON |
| `max_depth` | `256` | deserialize | how many `.{}` levels a document may nest before it is refused (a guard against hostile input, not a size limit) |
| `layout` | `.MULTILINE` | serialize | `.MULTILINE` writes one entry per line with four spaces per level, like `build.zig.zon`. `.COMPACT` writes one line |
| `hex_fields` | `&.{}` | serialize | field names written as hex (`.fingerprint = 0x4cc61d74dc93a20b`), at every depth. The others stay decimal. A name that is not a field, or a field that is not an integer or an optional integer, is a compile error |

## ZON

What the ZON paths read and write:

- `.{ .name = value }` structs and `.{ a, b }` lists
- `"..."` strings with Zig escapes, and `\\` multiline strings
- integers in any base (`10`, `0x1F`, `0o17`, `0b101`, `1_000`), floats (also `inf`, `-inf`, `nan`)
- `true`, `false`, `null`
- `.tag` enum literals
- `//` comments
- `.@"..."` names, for a name that is not a plain Zig identifier (such as `error`)

Out of scope: pointers other than slices, tuples (use an array), unions, char literals, and `@import`. Numbers are checked against the Zig grammar with `std.zig.parseNumberLiteral`, so `+1`, `012` and `1__0` are refused.

`MULTILINE` output for one record:

```zig
.{
    .id = 2,
    .name = "bar_1",
    .tags = .{
        "retail",
    },
    .status = .PENDING,
    .note = null,
}
```

## Type coverage

The generated JSON paths and both ZON paths take: `bool`, any integer width signed or unsigned, any float width, `[]const u8` as a string, a slice of any covered type, an optional of any covered type, an exhaustive enum, and a struct whose fields are all of those. ZON also takes a fixed-size array.

They refuse at compile time, naming the type: a non-slice pointer, a non-exhaustive enum, and a tuple. JSON `.STD` still takes any shape std takes, so a field outside the covered set is a strategy choice rather than a wall.

## Errors

| Call | Error set | Members |
| :- | :- | :- |
| `jzon.json.serialize` | `jzon.json.SerializeError` | `Jzon_Serialize_NoSpaceLeft` |
| `jzon.json.deserialize` | `jzon.json.DeserializeError` | `Jzon_Deserialize_*`, see below |
| `jzon.zon.serialize` | `jzon.zon.SerializeError` | `Jzon_ZonSerialize_NoSpaceLeft` |
| `jzon.zon.deserialize` | `jzon.zon.DeserializeError` | `Jzon_ZonDeserialize_*`, see below |

Both deserialize sets carry the same conditions:

| Condition | What it means |
| :- | :- |
| `UnknownField` | the document carries a key the type does not declare, under `unknown = .REJECT` |
| `MissingField` | the document left out a field that declares no default |
| `UnknownEnumValue` | a name the enum has no tag for |
| `Truncated` | the document ended early |
| `Unexpected` | what is there is not what the type wants: a syntax error, a value of the wrong shape, the same key twice, or nesting past the cap |
| `BadNumber` | number text the grammar does not allow, or a value the target type cannot hold |
| `BadEscape` | an escape sequence the rules do not spell |
| `OutOfMemory` | the allocator ran out |

A few members are never returned (`Jzon_Serialize_BadNumber`, `Jzon_Serialize_BadEscape`, `Jzon_Deserialize_NoSpaceLeft`, `Jzon_ZonSerialize_BadNumber`). They exist because every member of an inner set maps to a real member of the public one.

`jzon.lastFailure()` tells what a failed parse was about, for both formats: the field or tag name, the byte offset, or both. Read it right after the error, on the same thread.

```zig
const order = jzon.zon.deserialize(Order, allocator, text, .{}) catch |err| {
    const failure = jzon.lastFailure();
    std.debug.print("{t} at byte {d}, field '{s}'\n", .{ err, failure.offset, failure.field });

    return err;
};
```

Swapping a JSON strategy never changes what a caller has to handle. `docs/lld-en.md` lists the three places a path built from the type answers differently from `.STD`.

## Examples

Seven, in `examples/`. Each runs and exits, none is a server. Run them from `src/jzon`, because `zon_file` and `bench_deserialize` read `examples/order.zon` and `examples/order.json` by relative path. `zon_file` writes `.tmp/jzon_example_order.zon` and keeps it.

| Example | What it shows |
| :- | :- |
| [serialize](examples/serialize.zig) | a value into a fixed buffer, every write strategy, and what a buffer too small reports |
| [deserialize](examples/deserialize.zig) | a request body into a typed value on an arena, every read strategy, reset between bodies |
| [strings](examples/strings.zig) | `.COPY` against `.BORROW`, and what borrowing asks of the document's lifetime |
| [unknown_keys](examples/unknown_keys.zig) | `.REJECT` against `.SKIP` on a document carrying more than the type declares |
| [bench_serialize](examples/bench_serialize.zig) | what each write strategy costs per render, against the default's rate |
| [bench_deserialize](examples/bench_deserialize.zig) | what each read strategy costs per parse, on a minified document and a laid-out one |
| [zon_file](examples/zon_file.zig) | a real `.zon` file read into a typed record and written back |

Build them from the package with `zig build examples`, or from the repo root with `zig build jzon-examples`. The two bench examples want `-Doptimize=ReleaseFast`. A Debug build measures the safety checks rather than the paths.

A server example lives with the engine examples rather than in this package: `examples/http1_jzon.zig` reads a JSON request body into a record on the per-request arena and answers with a record rendered into a stack buffer. Build it from the repo root with `zig build zix-example-http1_jzon`.

## Testing

Two tiers, 822 tests, none of them needing anything installed:

```
zig build unit_edge-test     # 639, the in-file unit and edge tests under src/
zig build behaviour-test     # 183, what each piece does when handed what it wants
zig build all-test           # both
```

From the repo root the same steps are `jzon-unit_edge-test`, `jzon-behaviour-test`, and `jzon-all-test`.
