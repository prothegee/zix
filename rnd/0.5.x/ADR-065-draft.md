# ADR-065 Draft: drop the POOL and MIXED dispatch models

Working draft. All work happens on the `drop_pool_and_mixed_dispatch` branch. This file is the living tracker: the checkpoint list below is updated in place. Promoted to `docs/adr-*.md`. This file is kept as the working record.

## ADR-065: drop the POOL and MIXED dispatch models

**Status:** Accepted

**Context:** `DispatchModel` carried five values: `.ASYNC`, `.POOL`, `.MIXED`, `.EPOLL`, `.URING`. Five models across eight engines meant 40 dispatch loops to keep correct, and only three of them are actually maintained. `.EPOLL` and `.URING` are Linux-only, so `.POOL` also served a second job nobody chose it for: it was the silent fallback target off Linux.

That fallback is the real problem. Every engine's `run()` contained a branch like this:

```zig
.EPOLL => if (comptime builtin.target.os.tag == .linux)
    epoll_model.runEpoll(cfg, handler)
else blk: {
    common.logSystem(cfg, "EPOLL is Linux-only. Falling back to POOL.", .{});

    break :blk pool_model.runPool(cfg, handler);
},
```

A caller who configured a shared-nothing per-core loop and deployed to Windows got a thread pool instead. The log line was the only signal, and a server with no logger configured emitted nothing in release. The caller's throughput, memory, and latency profile all changed, silently.

`.POOL` and `.MIXED` were also not free to keep. `.POOL` needed a `ConnQueue` (mutex, condvar, growable ring) and two thread roles per engine, `.MIXED` needed a third accept-thread shape with its own stack-size workaround for `io.async` inline fallback. Both existed in every engine's `dispatch/` directory and in every engine's `common.zig`.

**Decision:** Keep the three maintained models. Reject an unsupported one instead of downgrading it.

- `DispatchModel` becomes `ASYNC = 0`, `EPOLL = 1`, `URING = 2`. Gapless, because nothing serializes the value: it is source-level config only.
- Off Linux, an engine's `run()` returns `error.DispatchModelUnsupported` for `.EPOLL` and `.URING`. It logs which model was rejected first, so an operator sees the cause and not just an error name.
- The check is one shared predicate, `src/utils/dispatch_support.zig`, consulted at the top of every `run()` before it opens a listener, spawns a timer thread, or detaches a TLS accept thread. A rejected config therefore leaves nothing behind.
- The 16 `dispatch/pool.zig` and `dispatch/mixed.zig` files are deleted, along with the `ConnQueue`, `WorkerCtx`, `PoolCtx`, and `AsyncWorkerCtx` helpers that only they used.
- `pool_size` is removed from all 8 configs, and `pool_stack_size_bytes` from `zix.Fix`. In `zix.Http2` and `zix.Grpc` `pool_size` was the `.EPOLL` / `.URING` worker count while `workers` was POOL/MIXED-only, so those two engines are repointed onto `workers`. All 8 engines now read the same field for the same purpose. Both defaulted to 0, so default behaviour is unchanged.
- The numbered per-model examples collapse to one unified example per engine (`examples/http1_basic.zig`, `examples/tcp_server.zig`, and so on), each picking its model per target at comptime:

```zig
const DISPATCH_MODEL: zix.Http1.DispatchModel = if (builtin.os.tag == .linux) .URING else .ASYNC;
```

**Four examples kept a Linux-only pin at the time of this decision** (compression on `.EPOLL`,
the WebSocket pump on `.EPOLL`, and the io_uring WebSocket demo on `.URING`), because those
features were installed by the multiplexed workers only. ADR-066 removed that limitation: the
features now run under `.ASYNC` as well, so no example pins a model any more.

**Consequences:**

- A caller outside this tree that set `.POOL`, `.MIXED`, `pool_size`, or `pool_stack_size_bytes` no longer compiles. That is the intent: a compile error names the problem, where the old fallback did not.
- `.ASYNC` is now the only portable model, and the six non-Linux targets in the cross-build matrix all use it. It is also the model to reach for on Linux when connections are long-lived (SSE, WebSocket).
- The `.URING` runtime fold to `.EPOLL` stays. That is a different thing: a capability gap on a platform that does support the model (an old kernel, a low `RLIMIT_MEMLOCK`, a sandbox), not a platform mismatch. It keeps its logged notice.
- The per-model test-runner matrix collapses to one runner row per engine. Two legs are lost and named here rather than left to be discovered: the `http1-drain` runner keeps only its URING leg, and `grpc-stream` now shares port 9032 with `grpc`.
- `tests/runner/common.zig:skipDispatchOffPlatform` previously substring-matched the label for `"epoll"` / `"uring"`. Collapsing the runner rows removed those words from every label, so the guard silently stopped matching anything. It is now an exact-match list of the Linux-only scenario labels, which cannot rot the same way unnoticed.
- `tests/behaviour/dispatch/platform_gate_test.zig` covers the predicate and the enum shape, and skips nothing. Three earlier tests that called each engine's `run()` to observe the rejection were removed: they could only ever execute off Linux, so they were a permanent skip on the platform they were developed on. What is lost is a runtime check that `run()` consults the predicate, which the compile still proves the call site of.
- This supersedes the `.POOL` / `.MIXED` parts of ADR-043 (per-engine `dispatch/` rollout) and ADR-058 (per-worker pool). The rest of both stands.
- `.KQUEUE` and `.IOCP` remain reserved names in ADR-050, and the same rule now applies to them: a model ships when it has a maintainer. Until then non-Linux targets use `.ASYNC`.

## Checkpoints

| Step | State |
| :- | :- |
| Config surface, all 8 `config.zig` gapless + `pool_size` removed | done |
| 16 `dispatch/{pool,mixed}.zig` deleted, dead helpers removed | done |
| `run()` switches reject instead of downgrading | done |
| Remaining `src/` references and comments | done |
| 34 numbered examples collapsed to 7 unified | done |
| Build wiring (`zix-build-examples.zig`, `zix-build-test_runner.zig`) | done |
| Tests, plus `tests/behaviour/dispatch/platform_gate_test.zig` | done |
| Local gate: `build-all-targets.sh` on `zig-0.16` and `zig-0.17` | done |
| Docs pass (README pair, hld / lld / concurrency / zix-config / coding-guideline / tests, en and id) | done |
| `examples` and `test-runner-all` wired into all 7 GitHub workflow legs | done |
| Cross-build CI green on all 7 platforms | PENDING, gates promotion |
| Isolate bench (perf gate) | PENDING, user-run |
| Promote to `docs/adr-*.md` | done |

## Local verification

`zig fmt` clean. `zig build test-all` is 1407/1407 with zero skips on both `zig-0.16` and `zig-0.17`. `zig build examples` green. `zig build test-runner-all` green, all 52 protocols. Full 7-target `scripts/build-all-targets.sh zig-0.16` reports `all targets passed`.

Note on that last one: a foreign target only COMPILES the runners, `zix-build-test_runner.zig` skips their execution. The CI legs are native, so they will actually run them. The local sweep is therefore no evidence of off-Linux runtime behaviour, which is exactly why CI green gates the promotion.

## Open before promotion

- **Windows POSIX scenarios are unverified.** `uds`, `uds-http`, `udp`, `udp-raw`, and `channel-ipc` need unix sockets or raw UDP, both recorded as by-design runtime errors on Windows during the platform port. If the Windows leg fails on those, they need adding to the Linux-only skip list (or a Windows-only one), which is a test-harness change, not an engine change.
- The perf gate has not been run. Dispatch loops are untouched, but the Http2 and Grpc `pool_size` to `workers` repoint sits on the `.EPOLL` / `.URING` worker-count read path.

###### end of adr-065 draft
