# uuidz
UUID generation and parsing in pure Zig, standard library only.

- One package, three UUID versions: v1 (time-based), v4 (random), v7 (time-ordered).
- Every version exposes the same surface: `init`, `initFromString`, `asString`, `asReffID`.
- Generation and parsing allocate nothing. The caller owns every buffer.
- `initFromString` accepts both the 36-char hyphenated form and the 32-char reference form.
- Strict version and variant validation on parse, so a string that is not the requested version is an error, not a silently accepted value.
- Builds on Zig 0.16 and 0.17.

For the architecture see `hld-en.md`, for the bit-level detail see `lld-en.md`.

<br>

## Import

`uuidz` ships inside `zix` and is reachable from it:

```zig
const zix = @import("zix");
const v4 = zix.uuidz.v4;
```

It is also a standalone package under `src/uuidz` with its own build files, so it can be depended on by itself. Add it as a path dependency in `build.zig.zon`:

```zig
.dependencies = .{
    .uuidz = .{ .path = "path/to/uuidz" },
},
```

Wire the module in `build.zig`:

```zig
const uuidz = b.dependency("uuidz", .{}).module("uuidz");
exe.root_module.addImport("uuidz", uuidz);
```

<br>

## Quickstart

Each version owns its own type. The usage is the same for all three.

```zig
const std = @import("std");
const uuidz = @import("uuidz");
const v4 = uuidz.v4;
const v7 = uuidz.v7;

pub fn main() !void {
    var io = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer io.deinit();

    const random_id = try v4.init(&io);
    const time_id = try v7.init(&io);

    var buf: [36]u8 = undefined;
    const random_str = random_id.asString(&buf);

    var ref: [32]u8 = undefined;
    const time_ref = time_id.asReffID(&ref);

    _ = random_str;
    _ = time_ref;
}
```

Parsing back from a string:

```zig
const v4 = uuidz.v4;

const uuid = try v4.initFromString("f47ac10b-58cc-4372-a567-0e02b2c3d479");
```

A parsed value carries the same methods as a generated one:

```zig
var buf: [36]u8 = undefined;
const text = uuid.asString(&buf);
```

<br>

## Version guide

| Version | Basis | Sortable | Leaks MAC | Recommended use |
| :- | :- | :- | :- | :- |
| v1 | Timestamp + node | No | Yes | Legacy systems that require v1 |
| v4 | Random | No | No | General purpose identifiers |
| v7 | Timestamp + random | Yes | No | Database keys, distributed systems |

<br>

## API surface

Every version struct exposes the same four calls:

| Call | What it does |
| :- | :- |
| `init(io) !Self` | Generate a new UUID |
| `initFromString(str) !Self` | Parse a 36-char or 32-char UUID string |
| `asString(buf) []u8` | Write the 36-char hyphenated form into a caller buffer |
| `asReffID(buf) []u8` | Write the 32-char reference form into a caller buffer |

The buffer sizes are constants:
- `BUFF_SIZE = 36` for `asString`
- `REFF_SIZE = 32` for `asReffID`

<br>

## Errors

`init` and `initFromString` return errors from a small set.

| Error | What it means |
| :- | :- |
| `InvalidUuidLength` | The string is neither 36 nor 32 bytes |
| `InvalidUuidFormat` | A hyphen is missing at position 8, 13, 18, or 23 |
| `InvalidHexCharacter` | A character is not a hex digit (0-9, a-f, A-F) |
| `InvalidUuidVersion` | The parsed value is not the requested version |
| `InvalidUuidVariant` | The parsed value does not carry the RFC 4122 variant |

<br>

---

###### end of readme
