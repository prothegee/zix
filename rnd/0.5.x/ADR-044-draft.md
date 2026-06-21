# ADR-044 (proposal record)

> This is part of 0.5.x

## Objective
Record the decision to support BOTH Zig 0.16.x and 0.17.x from a single source tree
via comptime version gating, rather than pinning the project to one Zig version.

## Background
zix is developed on Zig 0.16.0 (`zig-0.16`), while the rolling `zig` toolchain has
moved to 0.17.0-dev. The two versions differ in the std and build APIs in ways that
break compilation outright. The roadmap framed a version bump as blocking Phase 1, because a bump forces a re-baseline and was assumed to rewrite the io_uring path.

Two findings changed the calculus:

1. The io_uring rewrite was the feared large item, and it is a non-issue: the raw
   `std.os.linux.IoUring` is unchanged in 0.17, so the ring engines compile as-is.
2. Every other difference is either a parse-level operator change (`**`) with a single
   portable replacement, or a semantic API change that a comptime branch can carry on
   both versions at once.

So dual support is mechanical, not a re-baseline. Pinning one version would either
strand 0.16 users or block adoption of the current toolchain, for no benefit.

## Decision
Support 0.16.x and 0.17.x simultaneously. Introduce `ZIG_SEMVER`, a named comptime
constant over `builtin.zig_version`, and gate every version-specific difference on it.

### ZIG_SEMVER: one named constant, two contexts

`ZIG_SEMVER` exposes `pub const MAJOR`, `MINOR`, `PATCH` (each a `usize` from
`builtin.zig_version`). It exists in exactly two places, because build.zig and the zix
module are separate compilation contexts and build.zig cannot import the module:

| Copy | Location | Purpose |
| :- | :- | :- |
| build-only | `build.zig` | `ensureSupportedZig` guard and the `dirExists` build-root branch |
| public | `src/lib.zig` (`zix.ZIG_SEMVER`) | source-code version gates and external consumers |

The underlying source of truth is `builtin.zig_version`. `ZIG_SEMVER` is the named
surface. No third copy is created. Source files reach the public copy through a
circular `@import` of `lib.zig` (which Zig resolves for a comptime const): `logger.zig`
uses `../lib.zig`, `tcp/http1/core.zig` uses `../../lib.zig`, `udp/packet.zig` uses
`../lib.zig`. Test files import the module directly as `@import("zix").ZIG_SEMVER`.

### The gate, and the one exception

Semantic differences (a removed or renamed member, changed reflection) are gated:

```zig
if (comptime ZIG_SEMVER.MINOR == 16) { /* 0.16 code, kept as-is */ }
else                                  { /* 0.17 form */ }
```

A comptime-dead branch is never semantically analyzed, so 0.16 never sees the 0.17 API
and vice versa. The 0.16 code is preserved byte-for-byte on its branch.

The exception is the `**` operator. Its 0.17 rejection is a PARSE (AstGen) error that
fires over the whole file before any comptime branch is eliminated, so `**` inside a
dead 0.16 branch still breaks 0.17. It cannot be gated. The portable replacement is
`@splat`, which is byte-identical on 0.16, so `**` becomes one unconditional `@splat`.

### ensureSupportedZig

`build.zig` fails fast with a readable `@compileError` when the compiler is outside
0.16.x or 0.17.x, instead of a deep version-specific type error. Anything outside that
range needs its own port and ADR first.

## Difference inventory (how each is handled)

| # | Difference | 0.16 form | 0.17 form | Handling |
| :- | :- | :- | :- | :- |
| 1 | std.Build root field | `b.build_root` | `b.root.root_dir` | gated branch in `dirExists` |
| 2 | `**` repeat (array + string) | `X ** N` | parse error | unconditional `@splat` (6 sites) |
| 3 | `std.fmt.bufPrintZ` | `bufPrintZ(buf, fmt, args)` | removed | gated -> `bufPrintSentinel(buf, fmt, args, 0)` |
| 4 | `std.ascii.indexOfIgnoreCase` | `indexOfIgnoreCase` | renamed `findIgnoreCase` | gated rename |
| 5 | `@typeInfo` struct reflection | `.@"struct".fields` | `field_names` + `field_types` | gated branch |
| 6 | `std.meta.Int` | `std.meta.Int(sign, bits)` | removed | gated -> `@Int(.unsigned, bits)` |
| 7 | io_uring backend | `std.os.linux.IoUring` | unchanged | no change needed |

## Consequences

Good:
- One source tree serves both the stable 0.16 line and the current 0.17 toolchain. No
  fork, no per-version branch.
- The 0.16 path is preserved verbatim behind every gate, so the validated 0.16 behaviour
  is untouched. New versions are added in the `else`, not by rewriting the old code.
- `ZIG_SEMVER` centralizes the version check, so a future 0.18 port is a search for
  `ZIG_SEMVER.MINOR` plus the parse-level sweep, not a rediscovery.
- The roadmap's Phase-1-blocking version decision is removed: the campaign can run on
  either toolchain.

Cost:
- Two `ZIG_SEMVER` copies (build-only and public) must stay in sync. They are three
  trivial lines over the same `builtin.zig_version`, so drift is unlikely, and the doc
  comment in each forbids a third copy.
- Each gated site carries both forms, so the version-specific code is slightly longer.
  This is the price of preserving the 0.16 path exactly.
- The `**` sites change the 0.16 source line (to `@splat`) even though behaviour is
  identical, because that operator cannot be dual-pathed.
- A new compiler release can add differences not covered here. `ensureSupportedZig`
  bounds the supported range so an unsupported compiler fails with a clear message
  rather than a deep error.

## Status
Proposed. Implementation landed and verified: zix builds and passes `test-all`,
`examples`, and the live `test-runner-all` (56 protocols) on both 0.16.0 and
0.17.0-dev.902. Pending fold into `docs/adr-en.md` and `docs/adr-id.md` (the Indonesian
version keeps the English technical terms), mirroring the ADR-043 process.
