# ADR-058 draft: per-worker stream-slot pool for the multiplexed engines

Lean note. The full record lives in `docs/adr-en.md` / `docs/adr-id.md` (ADR-058).

## Decision in one line

On the multiplexed (`.EPOLL` / `.URING`) engines, borrow each stream's slot from a per-worker pool on stream open and return it on close, so resident stream memory tracks concurrent streams, not `connections * max_streams`.

## The problem

Each multiplexed connection reserved a full stream table at accept: `max_streams` slots, each carrying an inline header table plus body / scratch buffers, whether the connection was busy or idle. Memory scaled with connection count, not in-flight work. At high connection counts `zix.Http2` held about 6x more than the work needed (4096c), and `zix.Grpc` about 12x more (1024c). Buffer-size shrinks did not close it: the bulk was the table itself, provisioned at peak per connection.

## The pool

A thread-local free-list of stream slots, shared across every connection on the worker (shared-nothing per worker, no atomics). A connection borrows a slot on stream open (`acquireStream` in `mux.zig`, `acquireGrpcStream` in `grpc/core.zig`) and returns it on close (`releaseStream` / `releaseGrpcStream`), reusing the slot's buffers, so the steady state does no per-stream allocation. `MuxConn.streams` / `GrpcMuxConn.streams` becomes a `max_streams`-wide pointer array (`[]*Stream`, about 1 KiB per connection) in place of the inline table, and the eager per-connection body / scratch backing is dropped.

## Scope

- Multiplexed engines only: `zix.Http2` (`src/tcp/http2/mux.zig`) and `zix.Grpc` (`src/tcp/http2/grpc/core.zig`), where one worker drives many connections, so the worker is the natural owner of stream state.
- The blocking `.ASYNC` / `.POOL` / `.MIXED` paths are excluded: each connection is its own thread with its own local arrays, so a per-worker pool of one buys nothing.
- `zix.Http1` WebSocket is a future candidate (it reuses the Http1 slab, a different memory model).

## Consequence: folded defaults

With memory decoupled from `max_streams`, the advertised concurrency is cheap. Defaults fold on both engines: `max_streams` 16 to 128 (a client opening 100 parallel streams is no longer refused) and `max_body` 64 KiB to 16 KiB (a safer general default than the arena-era band-aid). `max_header_scratch` stays 4 KiB.

## Note

Both engines showed a both-axes result: memory down AND throughput up 8 to 20 percent, because the pooled hot slots (LIFO reuse) have a tighter cache working set than the old sparse per-connection table. Post-pool read-buffer and body-buffer shrinks were demand-paged no-ops (the high-connection residual is kernel socket buffers, not app buffers), so the pool is the memory lever.
