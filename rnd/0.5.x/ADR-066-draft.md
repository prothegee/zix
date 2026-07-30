# ADR-066 Draft: every feature works under .ASYNC, on every platform

Working draft. All work happens on the `drop_pool_and_mixed_dispatch` branch, on top of ADR-065.
This file is the living tracker: the checkpoint list below is updated in place. Promoted to
`docs/adr-*.md`. This file is kept as the working record.

## ADR-066: every feature works under .ASYNC, on every platform

**Status:** Accepted

**Context:** ADR-065 left `.ASYNC` as the only model available off Linux. That is only useful if
`.ASYNC` can actually serve what the engine advertises. It could not.

Three separate gaps, found by auditing rather than by a failing test, because none of them fail on
the machine the work was done on:

1. **Features the multiplexed workers installed and `.ASYNC` did not.** Response compression and
   the response cache are per-worker threadlocal switches, installed once per worker by
   `dispatch/epoll.zig` and `dispatch/uring.zig`. `.ASYNC` has no worker: `io.async` hands each
   connection to whichever pool thread is free, so nothing ever installed them. A server with
   `compress = true` on `.ASYNC` returned uncompressed bodies with no error. The engine-owned
   WebSocket promotion was worse: `core.zig` took the handoff and dropped it, ending the
   connection.

2. **A two-way platform split that silently targeted the wrong kernel.** Six files branched
   `if (windows) ... else <Linux syscall>`, so macOS, FreeBSD, NetBSD and OpenBSD fell into the
   Linux branch and issued Linux syscall numbers. `tls_serve.zig` is the `.ASYNC` TLS path, so
   TLS over `.ASYNC` was broken on four of the seven supported platforms. It compiled, which is
   why the cross-build sweep never caught it, and those four legs had never been run.

3. **Protocols with no portable path.** HTTP/3's `runSingle` logged a line and returned void off
   Linux, so `run()` reported success and never bound a socket. Unix-domain sockets bound a
   relative path, which the Windows AF_UNIX bind rejects outright, and the channel IPC pair used
   `/tmp/...`, a location Windows does not have.

**Decision:** `.ASYNC` is not a reduced model. Anything the engine offers works under it, on every
supported platform. A feature may be faster on a multiplexed model, never absent from `.ASYNC`.

- **Use `std.Io` wherever it reaches.** A raw accepted descriptor becomes a `std.Io.net.Stream`
  and is driven through the stream reader / writer, with no OS branch at all. Handshake secrets
  come from `io.randomSecure`, which is safe from a plain `std.Thread` and carries the platform's
  CSPRNG. This is the 0.16 answer to portability, and it replaces hand-rolled syscall shims.
- **Where `std.Io` does not reach, split three ways and guard the Linux branch.** `sendfile`,
  `recvmmsg` / `sendmmsg`, `epoll`, `io_uring` and `socketpair` have no `std.Io` equivalent. Those
  get a comptime `windows` / `linux` / `posix` split, where posix covers macOS and the three BSDs.
  A two-way split is the defect in context item 2 and must not reappear.
- **New shared substrate**, one responsibility each:

| Module | Owns |
| :- | :- |
| `utils/fd_io.zig` | blocking read / write / close / readiness on a raw descriptor |
| `utils/socket_pair.zig` | a connected descriptor pair, socketpair on POSIX, loopback on Windows |
| `utils/socket_path.zig` | where a local socket lives, absolute and identical for both ends |
| `utils/async_cache.zig` | the response cache for `.ASYNC`, one per io pool thread, plus reclaim |

- **The `.ASYNC` cache is threadlocal, not shared and not per connection.** Per connection it would
  die before it ever hit. Shared it would need a lock on the response path. Threadlocal matches the
  shared-nothing design the multiplexed workers already use. A threadlocal has no destructor and a
  `ResponseCache` owns an arena plus an mmap slab, so every cache is recorded in a registry and the
  accept loop reclaims them all on exit.
- **HTTP/3 gains a portable fallback**, mirroring the one `udp` already had: one datagram per
  receive over `std.Io` instead of a `recvmmsg` batch, reusing the QUIC state machine unchanged.
  The send helpers only queue into the batch, so a `flushPortable` on `SendBatch` was the only new
  primitive needed.
- **Local socket paths are resolved, not written literally.** Both ends derive the same absolute
  path from the same working directory, so no shared state and no platform-specific literal.

**Consequences:**

- The four examples ADR-065 pinned to a multiplexed model all take the per-target idiom. No
  example pins a dispatch model any more, so every one of them starts on every platform.
- `examples/http1_websocket_uring.zig` is deleted. Under the idiom `http1_websocket.zig` already
  runs `.URING` on Linux and so already exercises `websocket.pumpRing`, which made the separate
  example redundant. Its `/ws` echo route moved across, next to the existing `/ws/:room-id` rooms
  demo, and its runner became `test-runner-http1-websocket-echo` on the surviving port. Port 9029
  is retired, not reused.
- `tests/runner/common.zig:linux_only_labels` is now empty. Every one of the 52 runner scenarios is
  expected to pass on every platform.
- 85 unit / integration / edge tests dropped their `!= .linux` skip guard, because what made them
  Linux-only was the test harness (`socketpair`, `pipe2`, `memfd_create`) and not the behaviour
  under test. Eight logger tests traded their `!= .linux` guard for a narrower `== .windows` one:
  they read a log file back through `openat(AT.FDCWD)`, which Windows has no equivalent for, so
  they now run on macOS and the three BSDs where they never did before.
- `.ASYNC` remains slower than a multiplexed model under load. Nothing here changes that, and
  nothing here touches the `.EPOLL` / `.URING` install path: their per-worker cache and compression
  setup is byte for byte what it was.
- A caller on macOS or a BSD who was somehow relying on the old TLS behaviour was relying on
  undefined behaviour. There is no compatibility story to preserve.

## Checkpoints

| Step | State |
| :- | :- |
| Three-way guard on the 6 two-way-split files, TLS `.ASYNC` fixed | done |
| `utils/fd_io.zig`, `socket_pair.zig`, `socket_path.zig`, `async_cache.zig` | done |
| Compression under `.ASYNC` (http1, http) | done |
| Response cache under `.ASYNC` (http1, http, http2, grpc) | done |
| Cleartext WebSocket pump under `.ASYNC` (http1) | done |
| HTTP/3 portable datagram fallback | done |
| UDS + channel IPC socket paths resolved absolutely | done |
| Runner skip list emptied | done |
| 85 tests unskipped off Linux | done |
| Example pins removed except `_uring` | done |
| Local 7-target sweep, `zig-0.16` | done, `all targets passed` |
| Cross-build CI green on all 7 platforms | PENDING, gates promotion |
| Isolate bench (perf gate) | PENDING, user-run |
| Promote to `docs/adr-*.md` | done |

## Local verification

`zig fmt` clean. `zig build test-all` is 1422/1422 on both `zig-0.16` and `zig-0.17`.
`zig build test-runner-all` green, all 52 protocols. The full 7-target
`scripts/build-all-targets.sh zig-0.16` reports `all targets passed`, with `test-all`, `examples`
and `test-runner-all` compiling for every triple.

Each new behaviour was proven by forcing `.ASYNC` on Linux and running the real runner, not by
inspection:

| Proven | How |
| :- | :- |
| compression under `.ASYNC` | `http1-compression` and `http-compression` runners, both PASS |
| response cache under `.ASYNC` | `http1-cache` runner, PASS |
| WebSocket under `.ASYNC` | `http1-websocket` runner, PASS |
| HTTP/3 portable fallback | `http3` runner forced onto `runFallback`, PASS (handshake plus two multiplexed requests) |
| UDS and channel IPC paths | `uds`, `uds-http`, `channel-ipc` runners, PASS |

## What the cross-build sweep caught

Unskipping the tests was not free, and the local sweep is what surfaced it. Four legs failed on the
first run after the unskip (`x86_64-windows`, `aarch64-macos`, `x86_64-netbsd`, `x86_64-openbsd`),
all of them test-harness portability rather than engine behaviour:

| Cause | Fix |
| :- | :- |
| `memfd_create` in an SSE test helper | replaced with a connected pair, no seek needed |
| `std.Io.Threaded.pipe2` in 8 test sites | replaced with `socket_pair.Pair` |
| `[2]i32` for descriptors | `[2]std.posix.fd_t`, since a Windows handle is a pointer |
| `-1` and `3` as literal descriptors | the existing `TEST_FD` sentinel idiom |
| `std.posix.read` / `std.posix.system.{write,close}` in test regions | `fd_io`, which has a Windows path |
| `openat(AT.FDCWD)` in the logger tests | narrowed to a `== .windows` skip |

**Lesson for the next sweep of this kind:** a per-test-block codemod misses helper functions defined
*outside* the test blocks, which is exactly where `makeMemFd` and `makePair` lived. Scan the whole
file for the Linux-only primitive, not just the block that carries the guard.

## Open before promotion

- **The four non-Linux legs have still never run.** Everything above is either a Linux run of the
  portable path or a cross-compile. Only CI can confirm macOS and the BSDs.
- **111 `!= .linux` skip guards remain**, mostly in `dispatch/epoll.zig` and `dispatch/uring.zig`
  where they are correct, plus a tail that uses Linux syscalls directly in test setup. Reducing
  that tail is worthwhile but is not a blocker.
- The perf gate has not been run. The `.EPOLL` / `.URING` install path is untouched, but
  `handleConnection` and `connEntry` gained per-connection switch installs on the `.ASYNC` path.

###### end of adr-066 draft
