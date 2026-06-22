## Zix Coding Guideline

How code is written in zix, derived from the existing implementation. This is the house style for `src/`, `tests/`, `examples/`, and the build files. Each rule names a real place in the tree so the convention can be checked against live code, not just asserted.

The guiding principle behind every rule below: code reads like the code already around it. Match the surrounding file's naming, comment density, and idiom before introducing a new one.

---

## 1. Source layout

Each subsystem is one Zig file-as-struct namespace, exported once from `src/lib.zig`. A subsystem's public type module is `PascalCase.zig` (`Tcp.zig`, `Udp.zig`, `Http1.zig`, `Channel.zig`), and it only re-exports that domain's surface:

```zig
//! zix tcp

pub const Server = @import("server.zig").Server;
pub const Client = @import("client.zig").TcpClient;
pub const HandlerFn = @import("server.zig").HandlerFn;
pub const DispatchModel = @import("config.zig").DispatchModel;
pub const ServerConfig = @import("config.zig").TcpServerConfig;
```

> Give each subsystem one namespace type (`zix.Http1`, `zix.Grpc`, ...). Put implementation in lowercase files (`server.zig`, `config.zig`, `client.zig`) and re-export only the public names from the `PascalCase.zig` aggregator.

The lowercase implementation files carry the logic, the PascalCase file is the door. `lib.zig` is the single root: it lists each subsystem (`pub const Tcp = @import("tcp/Tcp.zig");`) and groups loose helpers under a namespace struct (`pub const utils = struct { ... }`).

> A subsystem becomes public only when it has a line in `src/lib.zig`. Nothing reaches `zix.*` by accident.

**Test discovery is not recursive.** Every new `src/` file that has tests MUST get its own `std.testing.refAllDecls(@import("..."))` line in the `lib.zig` unit-test block, grouped under its engine comment. Miss it and the file's tests silently never run while unit-test still exits 0.

```zig
test "zix tests: unit test" {
    // # zix.Http
    std.testing.refAllDecls(@import("tcp/http/router.zig"));
    std.testing.refAllDecls(@import("tcp/http/response.zig"));
    // ... one line per file with tests
}
```

> After adding a `src/` file with tests, add its `refAllDecls` line in `src/lib.zig` in the same change. No exceptions.

---

## 2. Naming

| Kind | Rule | Example |
| :- | :- | :- |
| Public type module file | `PascalCase.zig` | `Http1.zig`, `Channel.zig` |
| Implementation file | `lowercase.zig` | `server.zig`, `config.zig` |
| Type / struct / enum | `PascalCase` | `TcpServerConfig`, `DispatchModel`, `RespSink` |
| Function | `camelCase` | `serveDispatch`, `frameRespond`, `uringUnavailableReason` |
| Field / variable / const binding | `snake_case` | `dispatch_model`, `max_recv_buf`, `pool_size` |
| Domain / public / config enum value | `UPPER_CASE` | `ASYNC`, `POOL`, `EPOLL`, `URING` |
| Error | `error.PascalCase` | `error.PortNotConfigured`, `error.ConnectionClosed` |
| Comptime version constants | `UPPER_CASE` | `ZIG_SEMVER.MAJOR` |

Enums that model a public, domain, or config choice are `UPPER_CASE` (`DispatchModel`, content type, status, logger level). The narrow exceptions kept in-tree are internal control-flow enums (`keep_alive` / `close` style outcomes) and protocol-mirroring values (WebSocket `text` / `binary` opcodes that mirror the wire name). When in doubt, `UPPER_CASE`.

**Never use a 2-to-5 character name when it is not self-evident.** One-character names are allowed only for `i` / `n` loop and count idioms. Spell out the rest (`handler`, not `h`; `config`, not `cfg` in new public surface, though `cfg` is an accepted local in existing dispatch code, match the file).

> Name for the reader who has not seen the file. If a short name needs a comment to be understood, it is the wrong name.

---

## 3. File anatomy

Files follow a fixed top-to-bottom shape:

```zig
//! zix tcp config

const std = @import("std");
const Logger = @import("../logger/logger.zig").Logger;

// --------------------------------------------------------- //

/// Connection dispatch model. ...
pub const DispatchModel = enum(u8) { ... };

// --------------------------------------------------------- //

/// TCP stream server configuration. ...
pub const TcpServerConfig = struct { ... };

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix test: TcpServerConfig, default field values" { ... }
```

1. **Module doc comment** `//! zix <subsystem>` on line 1, a short lowercase identity (`//! zix udp namespace aggregator`, `//! zix logger`). The one branded exception in `src/lib.zig` (`//! Zero sIX; 06;`) is intentional, never change it.
2. **Imports** with `const std = @import("std");` first, then project imports.
3. **Comment spacer** `// --------------------------------------------------------- //` separates major declarations.
4. **Declarations**, each preceded by its doc comment.
5. **Tests** at the bottom, fronted by a double comment spacer (two spacer lines), which is the one place a double spacer is allowed.

> Keep the order: header, imports, spacer-separated decls, then a double-spacer and the tests.

A comment spacer is a visual rule and separator. When the code gets longer, this grouping can act as a hint that it is already too large and can be refactored for maintainability. A leading spacer followed by a label line is the allowed form:

```zig
// --------------------------------------------------------- //
// Public surface re-exported from the dispatch helpers.

pub const HandlerFn = common.HandlerFn;
```

---

## 4. Doc comments

Public declarations carry a `///` doc comment. Use the label set with a `:` after the subject, never the verb form, never `;` as a prose separator:

- `Note:` (title case, not `NOTE:`)
- `Param:` with entries `name - type (description)`, a single space around the `-`, no column-aligning padding
- `Return:` (not `Returns`), entries are `-` bulleted outcome lines, never a bare type line
- `Usage:` only when non-obvious to a junior dev, and the code sample is wrapped in a ```zig fence

```zig
/// THE ONLY SOURCE OF TRUTH for Zig SEMVER for zix source code.
///
/// Note:
/// - Do not create in other place!
pub const ZIG_SEMVER = struct { ... };
```

Config fields each get a one-line `///` that states the unit, the default, and what 0 or null means:

```zig
/// Socket receive timeout per accepted connection in milliseconds (SO_RCVTIMEO). 0 = disabled.
recv_timeout_ms: u32 = 0,
/// Optional logger. When non-null, ... Caller owns. Must outlive the server.
logger: ?*Logger = null,
```

> Do not pad two-to-four spaces after a label `:`. The exception is a multi-line `Note:` bullet whose continuation lines align under the text. Write `Return:` outcomes as `-` bullets.

---

## 5. Code formatting (blank line between phases)

Run `zig fmt .` before any commit. Beyond formatting, distinct phases of a function body are separated by one blank line for human readability, even without a comment. The phase boundaries:

| Boundary | Blank line before |
| :- | :- |
| Guard / early return -> main logic | the first non-guard statement |
| Preparation / build -> send / write / commit | the first write or commit |
| Computation -> return | the `return` (especially a multi-line struct literal) |
| `defer x.deinit()` -> main execution | the first real statement |

```zig
pub fn init(config: TcpServerConfig) !Self {
    if (config.port == 0) return error.PortNotConfigured;

    return .{ .config = config };
}
```

```zig
var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
defer threaded.deinit();

const cfg = TcpServerConfig{ .io = threaded.io(), .ip = "127.0.0.1", .port = 9300 };
```

Exceptions where no blank line is needed: a mutex guard (`defer unlock` directly above its critical section) and same-phase setup chains (`defer free(x)` above the loop that uses `x`).

> After writing a function body, scan every line for a phase boundary. A guard's closing `}` and a single-line `if (...) return ...;` are each followed by a blank line. The last computation before a `return` is preceded by one.

---

## 6. Configuration: flat, no builder

Every config is one flat struct in `*/config.zig`. No nested sub-configs, no fluent builder. Required fields (`io`, `ip`, `port`) have no default and come first, every other field carries an explicit default:

```zig
pub const TcpServerConfig = struct {
    io: std.Io,            // required, caller-provided, must outlive the server
    ip: []const u8,        // required
    port: u16,             // required, must be non-zero
    dispatch_model: DispatchModel = .ASYNC,
    kernel_backlog: u31 = 4096,
    max_recv_buf: usize = 4096,
    // ...
};
```

A new tunable is a new top-level field, not a builder method or a nested object. When a field is genuinely cross-engine, it is added across all engine configs for consistency. A field scoped to one capability (for example the response-cache or compression knobs) is added only to the engine configs that have that capability, matching the existing footprint rather than all 8.

> Add a top-level field. Give it an explicit default and a one-line doc stating unit and the meaning of 0 / null.

---

## 7. Public type shape (lifecycle)

A server type is specialized over its comptime handler so `run` takes no handler argument, matching the `zix.Http1` / `zix.Grpc` shape. Every type uses `const Self = @This();` and the `init` / `deinit` / `run` lifecycle:

```zig
fn TcpServerImpl(comptime handler: HandlerFn) type {
    return struct {
        config: TcpServerConfig,

        const Self = @This();

        pub fn init(config: TcpServerConfig) !Self {
            if (config.port == 0) return error.PortNotConfigured;

            return .{ .config = config };
        }

        pub fn deinit(_: *Self) void {}

        /// Listen and serve. Selects the concurrency model from config.dispatch_model.
        pub fn run(self: *const Self) !void {
            return serveDispatch(self.config, handler);
        }
    };
}
```

- `init` validates required fields first and returns an error (`error.PortNotConfigured`) rather than panicking.
- `deinit` always exists even when empty (`pub fn deinit(_: *Self) void {}`), so callers can `defer server.deinit()` uniformly.
- `io` is always caller-provided through config and must outlive the server. Zix does not own the event loop.

> Bake the handler into the type at comptime. Validate in `init`, free in `deinit`, serve in `run`. Keep the trio even when one is a no-op.

---

## 8. Dispatch model and platform fallback

Concurrency is one `DispatchModel` enum (`ASYNC`, `POOL`, `MIXED`, `EPOLL`, `URING`), each model in its own file under `dispatch/` (ADR-043), selected by a thin `switch` in the server. `.ASYNC = 0` is the zero value so a zero-init config gets a sane default.

Linux-only models degrade gracefully instead of vanishing: a comptime OS check folds `.EPOLL` to `.POOL` off Linux, and a runtime probe folds `.URING` to the EPOLL adapter when io_uring is unusable (commonly the `RLIMIT_MEMLOCK` cap), each logging the reason through `common.logSystem`:

```zig
.EPOLL, .URING => if (comptime builtin.target.os.tag == .linux)
    epoll_model.runEpoll(cfg, handler)
else blk: {
    common.logSystem(cfg, "EPOLL is Linux-only. Falling back to POOL.", .{});

    break :blk pool_model.runPool(cfg, handler);
},
```

> Prefer comptime gating for a build-time fact (`comptime builtin.target.os.tag`), a runtime probe only for a host-time fact (memlock, ring availability). Always log the fallback reason. Never let the server silently disappear after binding.

---

## 9. Error handling

- Errors are PascalCase on `error.` and describe the condition (`error.PortNotConfigured`, `error.ConnectionClosed`, `error.MessageTooLarge`, `error.BufferTooSmall`). Reuse the established names before inventing a new one.
- Validate inputs at the boundary (`init`) and return the error early as a guard, with a blank line after.
- Use `errdefer` to unwind a partial construction, `defer` for unconditional cleanup.

> Return a named error, do not panic on a recoverable condition. Pick the existing error name that fits before adding one.

---

## 10. Memory and allocators

There is no single "preferred" allocator. The allocator is chosen by the data's lifetime and ownership, and arena is the exception, not the default. In the live tree the general-purpose thread-safe allocator is the dominant one, arena shows up only where a genuine bulk-reset point exists, and the bounded hot-path table has its own custom allocator.

| Allocator | When | Where in tree |
| :- | :- | :- |
| `std.heap.smp_allocator` (general-purpose, thread-safe) | the default for long-lived and shared state: connection and stream maps, worker thread arrays, HPACK tables, per-connection state. Use it whenever the data has no clean single reset point or is touched from more than one thread | every `dispatch/` and `core.zig` |
| `std.heap.ArenaAllocator` | only when the lifetime is a true scope with one bulk reset and a single owner: the response-cache backing, the `zix.Http` per-connection arena | `utils/response_cache.zig`, `tcp/http/server.zig` |
| Demand-paged slab (custom contiguous) | the bounded hot-path connection table, one `mmap` carved per worker, no per-accept heap call, an empty slot is just `buf.len == 0` | `multiplexers/slab.zig` |
| `std.heap.page_allocator` | page-granular buffers handed to the kernel (the provided-buffer ring) | `tcp/http1/dispatch/uring.zig` |
| `std.testing.allocator` | tests only, it also catches leaks | every test block |

Arena is the wrong choice, use `smp_allocator`, when any of these hold:

- The data is shared across worker threads. Arena is not thread-safe.
- The lifetime has no single reset point, for example a connection or stream that lives indefinitely and frees objects individually (the idle-conn pool reuses, it does not bulk-reset).
- Objects are reclaimed one at a time rather than all at once.

So the CLAUDE rule "prefer arena if applicable" turns on "if applicable": in a shared-nothing, long-lived-connection, thread-per-core server that is the minority of allocation sites, which is why `smp_allocator` dominates the tree and the slab carries the hot path.

A buffer-owning type frees in `deinit`. Anything caller-provided (`io`, `logger`) is borrowed, documented as "caller owns, must outlive", and never freed by zix.

> Pick the allocator from the data's lifetime and ownership. Default to `smp_allocator` for shared or long-lived state, reach for arena only at a true single-owner bulk-reset scope, and use the slab for the bounded hot-path table. Do not force arena where the lifetime does not fit it.

---

## 11. Tests

Tests live at the bottom of the file they cover (Zig discovers them through `refAllDecls`). The dominant name is `test "zix test: <subject>, <case>"`, with domain-prefixed variants for an engine surface (`zix grpc:`, `zix http1:`, `zix fix:`):

```zig
test "zix test: TcpServerConfig, default field values" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const cfg = TcpServerConfig{ .io = threaded.io(), .ip = "127.0.0.1", .port = 9300 };
    try std.testing.expectEqualStrings("127.0.0.1", cfg.ip);
    try std.testing.expectEqual(@as(u16, 9300), cfg.port);
}
```

After implementing any new function, field, or behavior, add the tests covering it in the same change (unit, behaviour, edge, and integration when applicable). A file is not done, and the next file is not started, until the new code has tests.

> Co-locate tests with the code. Name them `zix test: subject, case`. New behavior ships with its tests, never after.

---

## 12. Comments and prose (in code and docs)

These apply to `//`, `///`, `//!`, and every markdown doc:

- A single `-` is allowed as a definer after a `:` subject or inside `()` (`Support: en - English, id - Bahasa`), and in a `name - type` param entry. It is not allowed as a free-floating clause separator.
- Diagrams are mermaid, not text-art.
- Directory trees use plain ASCII with the `|___` connector and `/`-prefixed directory entries, never Unicode box-drawing.

> Before moving on from any comment or doc block, scan each sentence for an em-dash or a `;` used as a separator and restructure it.

---

## 13. Zig version gating

Zix supports two Zig versions through one comptime source of truth, `zix.ZIG_SEMVER` (ADR-044). Version-specific branches are gated at comptime so only the active branch compiles, the inactive one is never type-checked into the binary:

```zig
if (comptime ZIG_SEMVER.MINOR == 16) {
    // 0.16 std.Io path
} else {
    // 0.17 std.Io path
}
```

`ZIG_SEMVER` is declared once in `src/lib.zig` and nowhere else. The build script keeps its own build-only copy.

> Gate a version difference at comptime against `ZIG_SEMVER`. Do not branch on the version at runtime, and do not redeclare the constant.

---

## 14. Commits and documentation

- Run `zig fmt .` before composing a commit message.
- One commit per file. Closely related, inseparable files in one new directory may share a single commit.
- Documentation comes in an `-en.md` / `-id.md` pair. When translating to Indonesian, keep the English technical term wherever a forced translation would drift from the established meaning (shared-nothing, slab, dispatch, hot path, throughput, comptime, and similar).

> Commit per file with a meaningful message after `zig fmt .`. Keep docs bilingual, and keep technical terms in English inside other languages translation.
