# ADR-050 draft: dispatch-model taxonomy and cross-platform backend matrix

Lean note. The full record lives in `docs/adr-en.md` / `docs/adr-id.md` (ADR-050).

## Decision in one line

Fix the meaning of each `DispatchModel`: the OS swaps the I/O backend, never the single-or-multi nature.

## The matrix

| Model | Concurrency | OS |
| :- | :- | :- |
| `.ASYNC` | single-core | all |
| `.POOL` | multi-core (thread pool) | all |
| `.MIXED` | multi-core (hybrid) | all |
| `.EPOLL` | multi-core, per-core | Linux |
| `.URING` | multi-core, completion ring | Linux |
| `.KQUEUE` | multi-core, per-core | macOS / BSD (reserved, not implemented) |
| `.IOCP` | multi-core, per-core | Windows (reserved, not implemented) |

## Two mismatch kinds

- Category error (a backend that cannot exist on the target OS, e.g. `.IOCP` on Linux): compile-time reject via `builtin.os.tag`.
- Capability gap (a backend that exists but the machine cannot use, e.g. `.URING` on an old kernel): fold to a working model with a logged notice.

No auto-select keyword: a value names exactly one behavior. Each engine's `dispatch/` folder carries one file per model (ADR-043).

## Note

`.KQUEUE` / `.IOCP` are reserved names only (this ADR + the concurrency reference), no empty source files. `zix.Udp` raw mode's current `.POOL` / `.MIXED` single-worker aliasing is a gap to close under this contract.
