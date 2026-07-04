# zix Config Reference

What every adjustable zix configuration field means, and how changing it affects a running process. Covers the server engines and the TLS context, plus shared components (the Logger) that any engine attaches by pointer. One section per config. Each field lists its default, what it controls, and the tuning trade-offs.

This is the user-facing companion to the internal `magic-number-in-src.md`: same columns, but indexed by config field instead of source location, and without the internal classification.

Note: a server attaches a Logger through its `logger` field (a pointer). The Logger's own sizing knobs live once on the Logger config (see the Logger section), not on each server config.

## How to read the columns

A cell is left blank when it does not apply (a required handle like `io` has no tuning trade-off).

| column | meaning |
| :- | :- |
| field | the config struct field name |
| default | the value used when the field is omitted |
| controls | what the field does |
| perf impact | where it sits (hot path, per-conn, per-worker, startup) and which metric it moves |
| how to tweak | direction of change for a goal |
| if lower | consequence of a smaller value |
| if higher | consequence of a larger value |
| knob consequence | the main risk if it is misconfigured |

## Dispatch model (shared by all TCP-family engines)

`dispatch_model` selects the whole concurrency strategy. It is required: set it explicitly, there is no default. Values:

| value | meaning |
| :- | :- |
| `.ASYNC` | one accept thread, one `io.async()` per connection. Best for low latency at moderate connection counts. |
| `.POOL` | N accept threads push connections to a shared queue, M pool threads handle them. Best for throughput under high connection counts. |
| `.MIXED` | N accept threads each dispatch via `io.async()`, no shared queue. Balanced throughput and latency. |
| `.EPOLL` | shared-nothing: each worker owns one SO_REUSEPORT listener plus one epoll instance. Best for very high connection counts. Linux-only, folds to `.POOL` elsewhere. |
| `.URING` | shared-nothing io_uring: same per-core topology as `.EPOLL`, completion-based so most syscalls are batched away. Linux-only, probes the ring at startup and falls back to `.EPOLL` then `.POOL`. |

## HTTP/1 (`Http1ServerConfig`)

| field | default | controls | perf impact | how to tweak | if lower | if higher | knob consequence |
| :- | :- | :- | :- | :- | :- | :- | :- |
| io | required | std.Io backend, must outlive the server | | | | | must be provided |
| ip | required | bind address | | | | | |
| port | required | bind port, must be non-zero | | | | | zero is rejected at init |
| dispatch_model | required | concurrency model (see table above) | picks the whole strategy | `.EPOLL`/`.URING` for high connection counts on Linux | | | wrong model caps throughput, non-Linux folds to `.POOL` |
| kernel_backlog | 1024 | TCP listen backlog before accept() | kernel accept queue depth | raise under bursty connection storms | new connections dropped during a burst | more kernel memory for the queue | too low drops connections during spikes |
| busy_poll_us | 50 | SO_BUSY_POLL spin window in microseconds for accepted connections (.EPOLL) | hot, kernel busy-spins before sleeping the worker | raise to cut tail latency under load, 0 to save idle CPU | shorter spin, more idle-sleep wakeups, higher tail latency | cores spin at 100% when idle | no-op without kernel SO_BUSY_POLL support |
| max_recv_buf | 16384 | bytes buffered per request header block and per EPOLL connection | per-conn memory and max request size | raise for large request headers | large requests rejected | more memory per connection | too low rejects valid large requests |
| large_body_rcvbuf | 0 | SO_RCVBUF applied only on the large-body path (a body bigger than the read buffer, ie uploads), 0 leaves the kernel default | upload ingest speed and per-conn memory while a large body is in flight | raise for faster upload ingestion | uploads ingest slower (narrow kernel-default window) | more memory during a large body (256 KiB targets about 256 MiB resident at 256c) | only the upload path touches it, small-request cells are unaffected |
| ws_recv_buf | 0 | per-connection receive buffer for WebSocket connections, 0 falls back to max_recv_buf | per-WS-conn memory and WS pipelined-burst depth | raise above max_recv_buf to hold a deeper pipelined burst | more compact-and-reread churn for WS | more memory per WS connection | .EPOLL sizes the recv buffer, .URING sizes the frame-accumulation buffer and unmask scratch, 0 reuses max_recv_buf |
| uring_send_buf_size | 16384 | per-connection send buffer for the .URING dispatch model (the send half, max_recv_buf covers recv) | per-conn memory under .URING | raise for larger single responses, lower to shrink per-conn memory | more buffer growth on big responses | more memory per connection | no effect under other dispatch models |
| uring_idle_pool_floor | 64 | warm idle-connection pool floor per worker under .URING (A2) | warm-pool memory vs allocator hits on new connections | raise to keep more connections warm for bursty churn, lower to shrink idle memory | more allocator hits after a quiet spell | more idle connections kept resident | warm cap is clamp(live_count, floor, ceiling), no effect under other models |
| uring_idle_pool_ceiling | 256 | absolute warm idle-pool ceiling per worker under .URING (A2), holds the warm set below live_count at high concurrency | resident memory at high connection counts | raise to keep more warm for reconnect, lower to shrink the resident set under churn | more allocator hits on reconnect at high concurrency | more closed connections kept resident (cache and TLB pressure) | the fix for the high-connection regression where the warm set tracked live_count, no effect under other models |
| compress | false | enable gzip/deflate/brotli response compression with Accept-Encoding negotiation | CPU vs body size, only pays off over a real network | enable when serving over a network, leave off for loopback benchmarks | | | on a loopback benchmark it is pure CPU cost |
| compression_min_size | 256 | minimum body size in bytes before compression is attempted | per-response check | raise to skip compressing small bodies | tiny bodies compressed for little gain | larger bodies sent uncompressed | too low wastes CPU on small bodies |
| compression_max_out | 262144 | max compressed output bytes across all codings | per-compressed-response cap | raise to compress larger bodies | larger bodies sent uncompressed | more CPU and memory before bailing | a body over this is sent uncompressed |
| max_headers | 16 | no-op with the lazy engine, kept for source compatibility | | | | | inert |
| workers | 0 | accept thread count, 0 = cpu_count | parallelism across cores | leave 0 (auto), or pin a count | fewer cores used | oversubscription and context-switching | ignored by `.ASYNC` |
| pool_size | 0 | pool thread count, 0 = max(10, cpu*2) | concurrency under `.POOL` | raise for many blocking handlers | queueing under load | more threads and memory | only used by `.POOL` |
| worker_stack_size_bytes | 524288 | worker thread stack for the .EPOLL/.URING/.POOL handler threads | per-thread RSS (demand-paged) | raise for deep handlers or large stack locals, lower to trim RSS | stack overflow in deep handlers | wasted RSS per worker | cost is low until the depth is used |
| worker_stack_compress_bytes | 2097152 | worker stack when compression is on, applied as a floor: effective stack is max(worker_stack_size_bytes, this) | per-thread RSS under .EPOLL/.URING with compression | raise if a compressing handler needs more | flate (about 230 KB on the handler frame) can overflow a small stack | wasted RSS per worker | no effect when compression is off |
| handler_timeout_ms | 0 | per-handler execution budget in ms, 0 = disabled | cooperative deadline | set to bound slow handlers | handlers cut off sooner | slow handlers run longer | handlers must check isExpired() for it to take effect |
| send_date_header | true | include the Date header in every response (RFC 7231) | 37 bytes per response | leave on for compliance, off to shrink responses | | | off drops a standard header |
| public_dir | "" | root directory for static file serving, empty disables it | disk I/O on static hits | set to serve static files for routes that match no handler | | | non-empty is validated at run(), a missing dir yields error.PublicDirNotFound |
| public_dir_upload | "u" | upload subdirectory under public_dir, a declarative path an upload handler writes to by convention | | set the upload path | | | relative to public_dir, the engine does not auto-wire uploads |
| response_cache | false | enable the per-worker response cache (ADR-036) | memory for cached responses | enable for hot, repeatable responses | | | off makes the cache API a no-op |
| cache_max_entries | 256 | cache slot count, rounded down to a power of two | per-worker memory = entries * value_bytes | raise for more distinct cached keys | fewer keys cached, more misses | more per-worker memory | per-worker, times the worker count |
| cache_max_value_bytes | 16384 | per-slot response cap, larger responses bypass the cache | per-slot memory | raise to cache larger responses | large responses bypass the cache | more per-worker memory | keep lean, caching pays off above a few KiB |
| cache_ttl_ms | 1000 | default cache freshness in ms | cache hit rate vs staleness | raise for higher hit rate, lower for fresher data | entries expire sooner, more misses | staler responses served | too high serves stale data |
| cache_max_total_bytes | 0 | optional ceiling on per-worker cache memory, 0 = no ceiling | caps total cache memory | set to bound cache RAM | effective entry count reduced to fit | uses the full entries * value_bytes | 0 disables the ceiling |
| tls | null | TLS context for https (opt-in), null = cleartext | enables TLS, a separate perf band | attach a context to serve https | | | null serves cleartext |
| logger | null | optional logger for lifecycle lines | | attach for server logging | | | per-request access logging is the handler's job |

## HTTP/2 (`Http2ServerConfig`)

h2c cleartext by default, h2-over-TLS when `tls` is set.

| field | default | controls | perf impact | how to tweak | if lower | if higher | knob consequence |
| :- | :- | :- | :- | :- | :- | :- | :- |
| io | required | std.Io backend | | | | | |
| ip | required | bind address | | | | | |
| port | required | bind port, non-zero | | | | | zero is rejected |
| dispatch_model | required | concurrency model | picks the strategy | `.EPOLL`/`.URING` on Linux for scale | | | `.URING` falls back to `.EPOLL`, off Linux both fold to `.POOL` |
| kernel_backlog | 1024 | TCP listen backlog | kernel accept queue | raise under connection storms | connections dropped during a burst | more kernel memory | too low drops connections |
| workers | 0 | accept thread count, 0 = cpu_count | parallelism | leave 0 (auto) | fewer cores used | context-switching | ignored by `.ASYNC` |
| pool_size | 0 | pool thread count, 0 = max(10, cpu*2) | `.POOL` concurrency | raise for blocking handlers | queueing | more threads | only used by `.POOL` |
| worker_stack_size_bytes | 524288 | worker thread stack for the .EPOLL/.URING/.POOL and TLS handler threads | per-thread RSS (demand-paged) | raise for deep handlers, lower to trim RSS | stack overflow in deep handlers | wasted RSS per worker | cost is low until the depth is used |
| busy_poll_us | 0 | SO_BUSY_POLL spin window in microseconds for accepted connections (.EPOLL / .URING) | hot, kernel busy-spins before sleeping the worker | set to e.g. 50 to cut tail latency under load | shorter spin, more idle-sleep wakeups | cores spin at 100% when idle | 0 leaves it unset, no-op without kernel SO_BUSY_POLL support |
| max_streams | 128 | max concurrent streams per connection (advertised SETTINGS_MAX_CONCURRENT_STREAMS) | per-conn slot pointer table, stream slots pooled per worker | raise for highly multiplexed clients | clients see REFUSED_STREAM sooner | wider pointer array, higher advertised concurrency | too low serializes a multiplexed client |
| max_frame_size | 16384 | MAX_FRAME_SIZE setting advertised to clients (bytes) | bytes per DATA frame | raise to send larger frames | more frames per response | larger per-frame buffers | bounded by the HTTP/2 spec range |
| max_header_scratch | 4096 | HPACK decode scratch per stream | per-stream buffer, pooled by concurrency | raise for large header sets | large header blocks rejected | more memory per concurrent stream | too low rejects valid headers |
| max_body | 16384 | max request body buffered per stream (bytes), larger is truncated | per-stream buffer, pooled by concurrency | raise for larger request bodies | bodies over this are truncated | more memory per concurrent stream | over-large wastes pool memory at peak concurrency |
| max_recv_buf | 32768 | per-connection read buffer floor (.EPOLL / .URING mux) | per-conn read buffer, hot | raise to cut read() and compaction for large frames | more reads and compactions for big frames | more memory per connection | reader is max(this, one max frame) |
| tls_write_buf_initial_bytes | 16384 | initial capacity of the per-connection TLS pending-write buffer (grows on demand) | per-conn, TLS path | raise to avoid early reallocation under big responses | more reallocations under large responses | more idle memory per TLS conn | minor, amortization only |
| response_cache | false | enable the per-worker response cache (ADR-036), opt-in via serveCached/sendCached | cache memory | enable for hot, repeatable responses | | | off makes the cache API a plain send |
| cache_max_entries | 256 | cache slot count (power of two) | per-worker memory | raise for more keys | more misses | more memory | times the worker count |
| cache_max_value_bytes | 16384 | per-slot response cap | per-slot memory | raise for larger cached responses | large responses bypass the cache | more memory | keep lean |
| cache_ttl_ms | 1000 | default cache freshness in ms | hit rate vs staleness | raise for hit rate, lower for freshness | sooner expiry, more misses | staler data | too high serves stale data |
| cache_max_total_bytes | 0 | per-worker cache memory ceiling, 0 = none | caps cache memory | set to bound cache RAM | entry count reduced to fit | full entries * value_bytes | 0 disables the ceiling |
| tls | null | TLS context for h2-over-TLS (ALPN h2), null = h2c | enables TLS | attach a context with ALPN h2 | | | browsers require ALPN h2 for HTTP/2 over TLS |
| logger | null | optional logger for lifecycle lines | | attach for logging | | | per-request logging is the handler's job |

## gRPC (`GrpcServerConfig`)

gRPC over HTTP/2. h2c cleartext by default, h2-over-TLS when `tls` is set.

| field | default | controls | perf impact | how to tweak | if lower | if higher | knob consequence |
| :- | :- | :- | :- | :- | :- | :- | :- |
| io | required | std.Io backend | | | | | |
| ip | required | bind address | | | | | |
| port | required | bind port, non-zero | | | | | zero is rejected |
| dispatch_model | required | concurrency model | picks the strategy | `.EPOLL`/`.URING` on Linux for scale | | | non-Linux folds to `.POOL` |
| kernel_backlog | 1024 | TCP listen backlog | kernel accept queue | raise under storms | dropped connections | more kernel memory | too low drops connections |
| workers | 0 | accept thread count, 0 = cpu_count | parallelism | leave 0 (auto) | fewer cores | context-switching | ignored by `.ASYNC` |
| pool_size | 0 | pool thread count, 0 = max(10, cpu*2) | `.POOL` concurrency | raise for blocking handlers | queueing | more threads | only used by `.POOL` |
| worker_stack_size_bytes | 524288 | worker thread stack for the .EPOLL/.URING/.POOL and TLS handler threads | per-thread RSS (demand-paged) | raise for deep handlers, lower to trim RSS | stack overflow in deep handlers | wasted RSS per worker | cost is low until the depth is used |
| busy_poll_us | 0 | SO_BUSY_POLL spin window in microseconds for accepted connections (.EPOLL / .URING) | hot, kernel busy-spins before sleeping the worker | set to e.g. 50 to cut tail latency under load | shorter spin, more idle-sleep wakeups | cores spin at 100% when idle | 0 leaves it unset, no-op without kernel SO_BUSY_POLL support |
| max_streams | 128 | max concurrent h2 streams per connection (advertised SETTINGS_MAX_CONCURRENT_STREAMS) | per-conn slot pointer table, stream slots pooled per worker | raise for highly multiplexed clients | clients see REFUSED_STREAM sooner | wider pointer array, higher advertised concurrency | too low serializes a multiplexed client |
| max_frame_size | 16384 | MAX_FRAME_SIZE advertised to clients (bytes) | bytes per DATA frame | raise for larger frames | more frames per message | larger per-frame buffers | bounded by the HTTP/2 spec range |
| max_header_scratch | 4096 | HPACK decode scratch per stream | per-stream buffer, pooled by concurrency | raise for large header sets | large header blocks rejected | more memory per concurrent stream | too low rejects valid headers |
| max_body | 16384 | max request body buffered per stream (bytes), larger is truncated | per-stream buffer, pooled by concurrency | raise for larger messages | messages over this are truncated | more memory per concurrent stream | over-large wastes pool memory at peak concurrency |
| max_recv_buf | 65536 | per-connection read buffer floor (.EPOLL / .URING) | per-conn read buffer, hot | raise to cut read() and compaction for large frames | more reads and compactions for big frames | more memory per connection | reader is max(this, one max frame) |
| tls_write_buf_initial_bytes | 16384 | initial capacity of the per-connection TLS pending-write buffer (grows on demand) | per-conn, TLS path | raise to avoid early reallocation under big replies | more reallocations under large replies | more idle memory per TLS conn | minor, amortization only |
| tls | null | TLS context for gRPC over TLS (ALPN h2), null = h2c | enables TLS | attach a context with ALPN h2 | | | gRPC runs on HTTP/2, needs ALPN h2 over TLS |
| logger | null | optional logger, lifecycle plus per-rpc | | attach for logging | | | |
| handler_timeout_ms | 0 | global handler timeout cap in ms, 0 = disabled | cooperative deadline | set to bound slow handlers | handlers cut sooner | slow handlers run longer | Route.timeout_ms and the grpc-timeout header tighten it further |
| compress | false | gzip DATA-frame compression for clients advertising grpc-accept-encoding: gzip | CPU vs message size | enable over a network | | | pure CPU cost on loopback |
| response_cache | false | enable the per-worker unary response cache | cache memory | enable for hot unary responses | | | off makes the cache API a plain send |
| cache_max_entries | 256 | cache slot count (power of two) | per-worker memory | raise for more keys | more misses | more memory | times the worker count |
| cache_max_value_bytes | 16384 | per-slot response-message cap | per-slot memory | raise for larger cached messages | large messages bypass the cache | more memory | keep lean |
| cache_ttl_ms | 1000 | default cache freshness in ms | hit rate vs staleness | raise for hit rate, lower for freshness | sooner expiry, more misses | staler data | too high serves stale data |
| cache_max_total_bytes | 0 | per-worker cache memory ceiling, 0 = none | caps cache memory | set to bound cache RAM | entry count reduced to fit | full entries * value_bytes | 0 disables the ceiling |

## HTTP (std-backed convenience engine, `HttpServerConfig`)

The standard library path. Same compression and cache field set as HTTP/1, plus arena and header-tier knobs.

| field | default | controls | perf impact | how to tweak | if lower | if higher | knob consequence |
| :- | :- | :- | :- | :- | :- | :- | :- |
| io | required | std.Io backend | | | | | |
| ip | required | bind address | | | | | |
| port | required | bind port, non-zero | | | | | zero is rejected |
| dispatch_model | required | concurrency model | picks the strategy | `.EPOLL`/`.URING` on Linux for scale | | | non-Linux folds to `.POOL` |
| kernel_backlog | 4096 | TCP listen backlog | kernel accept queue | raise under storms | dropped connections | more kernel memory | too low drops connections |
| busy_poll_us | 50 | SO_BUSY_POLL spin window in microseconds for accepted connections (.EPOLL) | hot, kernel busy-spins before sleeping the worker | raise to cut tail latency under load, 0 to save idle CPU | shorter spin, more idle-sleep wakeups, higher tail latency | cores spin at 100% when idle | no-op without kernel SO_BUSY_POLL support |
| max_recv_buf | 4096 | read buffer per request, over-size requests get 431 | per-conn memory and max request size | raise for large requests | requests rejected with 431 | more memory per connection | too low rejects valid requests |
| large_body_rcvbuf | 0 | SO_RCVBUF applied only while reading a large request body (uploads), 0 leaves the kernel default | upload ingest speed and per-conn memory while a large body is in flight | raise for faster upload ingestion | uploads ingest slower (narrow kernel-default window) | more memory during a large body (256 KiB targets about 256 MiB resident at 256c) | only the upload path touches it, small-request handlers are unaffected |
| body_read_timeout_ms | 30000 | max ms Request.body() waits for the next segment of a multi-segment body on the non-blocking .EPOLL / .URING fd | upload path only, bounds a stalled client | lower to drop stalled uploaders sooner | uploads from slow clients cut sooner | a stalled client holds the worker longer | the hot GET path has no body and never waits here |
| uring_send_buf_size | 16384 | per-connection send buffer for the .URING dispatch model (max_recv_buf covers recv) | per-conn memory under .URING | raise for larger responses, lower to shrink per-conn memory | more buffer growth on big responses | more memory per connection | no effect under other dispatch models |
| uring_idle_pool_floor | 64 | warm idle-connection pool floor per worker under .URING | warm-pool memory vs allocator hits on new connections | raise to keep more connections warm for bursty churn, lower to shrink idle memory | more allocator hits after a quiet spell | more idle connections kept resident | no effect under other dispatch models |
| compress | false | enable gzip/deflate/brotli with Accept-Encoding | CPU vs body size | enable over a network | | | pure CPU cost on loopback |
| compression_min_size | 256 | min body size before compression | per-response check | raise to skip small bodies | small bodies compressed | larger bodies skip compression | too low wastes CPU |
| compression_max_out | 262144 | max compressed output bytes | per-response cap | raise for larger bodies | larger bodies uncompressed | more CPU before bailing | over this is sent uncompressed |
| max_allocator_size | 4096 | initial arena capacity per connection, grows if exceeded | per-conn memory, reallocation | raise to avoid early arena growth | more arena growth events | more idle memory per connection | grows automatically anyway |
| max_client_response | 4096 | write buffer per response | per-response memory | raise for larger responses | smaller single-write responses | more memory per response | caps a single response write |
| max_request_headers | `.LARGE` | max request headers, over-tier rejected with 431 | parse storage | raise the tier for header-heavy clients | header-heavy requests rejected | more parse storage | custom values above 64 are capped at 64 |
| max_response_headers | `.MINIMAL` (16) | max custom response headers, arena-allocated to this size | per-response memory | raise the tier for many custom headers | extra headers cannot be set | more per-response memory | sized exactly per request |
| public_dir | "" | root directory for static file serving, empty disables it | disk I/O on static hits | set to serve static files | | | empty disables static serving |
| public_dir_upload | "u" | upload subdirectory under public_dir for multipart uploads | | set the upload path | | | relative to public_dir |
| conn_timeout_ms | 0 | connection lifetime guard in ms, 0 = disabled | background timer eviction | set to evict long-lived connections | connections cut sooner | longer-lived connections | should be >= handler_timeout_ms |
| handler_timeout_ms | 0 | per-handler budget in ms, 0 = disabled | cooperative deadline | set to bound slow handlers | handlers cut sooner | slow handlers run longer | handlers must check ctx.isExpired() |
| workers | 0 | accept thread count, 0 = cpu_count | parallelism | leave 0 (auto) | fewer cores | context-switching | ignored by `.ASYNC` |
| pool_size | 0 | pool thread count, 0 = max(10, cpu*2) | `.POOL` concurrency | raise for blocking handlers | queueing | more threads | only used by `.POOL` |
| worker_stack_size_bytes | 524288 | worker thread stack for the .EPOLL/.URING/.POOL handler threads | per-thread RSS (demand-paged) | raise for deep handlers or large stack locals, lower to trim RSS | stack overflow in deep handlers | wasted RSS per worker | cost is low until the depth is used |
| worker_stack_compress_bytes | 2097152 | worker stack when compression is on, applied as a floor: effective stack is max(worker_stack_size_bytes, this) | per-thread RSS under .EPOLL/.URING with compression | raise if a compressing handler needs more | flate (about 230 KB on the handler frame) can overflow a small stack | wasted RSS per worker | no effect when compression is off |
| response_cache | false | enable the per-worker response cache | cache memory | enable for hot responses | | | off makes the cache API a plain send |
| cache_max_entries | 256 | cache slot count (power of two) | per-worker memory | raise for more keys | more misses | more memory | times the worker count |
| cache_max_value_bytes | 16384 | per-slot response cap | per-slot memory | raise for larger cached responses | large responses bypass the cache | more memory | keep lean |
| cache_ttl_ms | 1000 | default cache freshness in ms | hit rate vs staleness | raise for hit rate, lower for freshness | sooner expiry, more misses | staler data | too high serves stale data |
| cache_max_total_bytes | 0 | per-worker cache memory ceiling, 0 = none | caps cache memory | set to bound cache RAM | entry count reduced to fit | full entries * value_bytes | 0 disables the ceiling |
| logger | null | optional logger, calls logger.access() per response | | attach for access logging | | | injects ctx.logger for handlers |

## TCP (`TcpServerConfig`)

| field | default | controls | perf impact | how to tweak | if lower | if higher | knob consequence |
| :- | :- | :- | :- | :- | :- | :- | :- |
| io | required | std.Io backend | | | | | |
| ip | required | bind address | | | | | |
| port | required | bind port, non-zero | | | | | zero is rejected |
| dispatch_model | required | concurrency model | picks the strategy | `.EPOLL`/`.URING` on Linux for scale | | | non-Linux folds to `.POOL` |
| kernel_backlog | 4096 | TCP listen backlog | kernel accept queue | raise under storms | dropped connections | more kernel memory | too low drops connections |
| max_recv_buf | 4096 | max payload bytes per frame, over-size closes the connection | per-conn memory and max frame | raise for larger frames | large frames close the connection | more memory per connection | too low closes valid large frames |
| uring_send_buf_size | 65536 | per-connection send buffer for the .URING framed model (max_recv_buf covers recv) | per-conn memory under .URING | raise for larger frames, lower to shrink per-conn memory | more buffer growth on big frames | more memory per connection | no effect under other dispatch models |
| uring_max_conns_per_worker | 65536 | max concurrent connections one .URING worker tracks (fd-indexed slab) | per-worker slab, demand-paged | raise for very high concurrency, lower to shrink the slab | connections rejected past the cap | larger upfront slab (demand-paged) | only the .URING model |
| workers | 0 | accept thread count, 0 = cpu_count | parallelism | leave 0 (auto) | fewer cores | context-switching | ignored by `.ASYNC` |
| pool_size | 0 | pool thread count, 0 = max(10, cpu*2) | `.POOL` concurrency | raise for blocking handlers | queueing | more threads | only used by `.POOL` |
| worker_stack_size_bytes | 524288 | worker thread stack for the .EPOLL/.URING/.POOL handler threads | per-thread RSS (demand-paged) | raise for deep handlers, lower to trim RSS | stack overflow in deep handlers | wasted RSS per worker | cost is low until the depth is used |
| recv_timeout_ms | 0 | socket receive timeout per connection (SO_RCVTIMEO), 0 = disabled | blocks recv past this | set to drop stalled peers | peers dropped sooner | slow peers tolerated longer | 0 waits indefinitely |
| send_timeout_ms | 0 | socket send timeout per connection (SO_SNDTIMEO), 0 = disabled | blocks send past this | set to drop slow consumers | consumers dropped sooner | slow consumers tolerated longer | 0 waits indefinitely |
| logger | null | optional logger, lifecycle plus per-connection close | | attach for logging | | | |

## UDP (`UdpServerConfig`)

The typed messaging path runs a single async receive loop. The batch and worker knobs apply to the raw-bytes path (`zix.Udp.Raw`, ADR-049).

| field | default | controls | perf impact | how to tweak | if lower | if higher | knob consequence |
| :- | :- | :- | :- | :- | :- | :- | :- |
| io | required | std.Io backend | | | | | |
| allocator | required | backing allocator, must be general-purpose | | | | | ArenaAllocator leaks broadcast snapshots |
| ip | required | bind address | | | | | |
| port | required | bind port, must be non-zero | | | | | zero rejected at init |
| allow_args | false | when true, init reads `--ip` / `--port` from the args it is passed | startup only | set true to override ip and port at runtime | | | args are ignored when false |
| endianness | `.LITTLE` | wire endianness contract with clients (the typed server relays raw bytes without decoding, the client applies it on every send and receive) | client-side per-packet conversion | `.LITTLE` for cross-language clients, `.BIG` for network order | | | must match across clients and server |
| conn_timeout_ms | 5000 | ms of silence before a client is considered disconnected | liveness tracking | lower for faster disconnect detection | clients dropped sooner | dead clients linger | too low drops slow but live clients |
| poll_timeout_ms | 2000 | receive poll interval in ms, sets disconnect check frequency | wakeup frequency | lower for more responsive checks | more frequent wakeups | slower disconnect detection | trades CPU for responsiveness |
| auto_ack | false | send a 0x06 ACK byte on successful receipt | one extra send per packet | enable for at-least-once feedback | | | adds reply traffic |
| error_report | false | send a 0x15 NACK byte on a malformed or oversized packet | one extra send on error | enable for error feedback | | | adds reply traffic |
| auto_echo | false | echo the received packet back as-is | one extra send per packet | enable for echo behavior | | | adds reply traffic |
| broadcast | false | relay the received packet to all connected clients | a send per connected client | enable for fan-out | | | per-packet cost scales with client count |
| dispatch_model | required | concurrency for the raw path, EPOLL/URING run per-core workers | picks the strategy | `.EPOLL`/`.URING` for the raw path at scale | | | typed path folds a non-ASYNC model to a single loop |
| workers | 0 | worker count for per-core models, 0 = cpu_count | parallelism | leave 0 (auto) | fewer cores | context-switching | only for EPOLL/URING |
| reuse_address | false | set SO_REUSEADDR + SO_REUSEPORT for multi-worker binding | enables kernel load-balancing | enable for per-core workers | | | required for multi-worker port sharing |
| recv_batch | 32 | datagrams received per recvmmsg syscall (raw path) | syscalls per batch | raise to cut syscalls under load | more syscalls per datagram | larger batch buffers | too low loses batching benefit |
| send_batch | 32 | replies coalesced per sendmmsg flush (raw path) | syscalls per flush | raise to cut syscalls under load | more flush syscalls | larger batch buffers | too low loses batching benefit |
| max_recv_buf | 1500 | max datagram size, receive buffer per slot (raw path) | per-slot memory | match to path MTU | larger datagrams truncated | more per-slot memory | 1500 is the common Ethernet MTU |
| busy_poll_us | 0 | SO_BUSY_POLL spin window in microseconds for the per-core raw worker socket (.EPOLL / .URING) | recvmmsg wake-up latency | set to e.g. 50 to cut wake-up latency under load | shorter spin, more idle-sleep wakeups | cores spin when idle | 0 leaves it unset, no-op without kernel SO_BUSY_POLL support |
| worker_stack_size_bytes | 524288 | worker thread stack for the per-core raw workers (.EPOLL / .URING) | per-thread RSS (demand-paged) | raise for deep handlers, lower to trim RSS | stack overflow in deep handlers | wasted RSS per worker | cost is low until the depth is used |
| gso_enabled | false | UDP GSO (UDP_SEGMENT): coalesce consecutive same-destination replies into one sendmsg per group | send-path syscalls | enable when replies burst to one peer (multi-packet flights) | | fewer send syscalls, lower CPU | probed at startup, off on kernels older than 4.18, helps only multi-packet same-peer batches |
| logger | null | optional logger, lifecycle plus per-datagram | | attach for logging | | | |

## HTTP/3 (`Http3ServerConfig`)

QUIC over UDP. Requires a TLS 1.3 context (no cleartext mode).

| field | default | controls | perf impact | how to tweak | if lower | if higher | knob consequence |
| :- | :- | :- | :- | :- | :- | :- | :- |
| io | required | std.Io backend | | | | | |
| allocator | required | backing allocator, general-purpose | | | | | |
| ip | required | bind address | | | | | |
| port | required | bind port, non-zero | | | | | zero is rejected |
| dispatch_model | required | concurrency: .EPOLL is an epoll readiness loop, .URING an io_uring completion loop, each one SO_REUSEPORT worker per core | picks the strategy | `.EPOLL`/`.URING` for multicore scale | | | ASYNC runs a single worker with CID demux, POOL/MIXED/EPOLL/URING run one per core. .URING falls back to .EPOLL when io_uring is unavailable |
| workers | 0 | worker count for per-core models, 0 = cpu_count | parallelism | leave 0 (auto) | fewer cores | context-switching | only for EPOLL/URING |
| recv_batch | 32 | datagrams received per recvmmsg syscall | syscalls per batch | raise to cut syscalls | more syscalls | larger buffers | too low loses batching |
| send_batch | 32 | packets coalesced per sendmmsg flush | syscalls per flush | raise to cut syscalls | more flushes | larger buffers | too low loses batching |
| max_recv_buf | 1500 | max datagram size, receive buffer per slot | per-slot memory | match to path MTU | datagrams truncated | more memory | 1500 is the common Ethernet MTU |
| busy_poll_us | 0 | SO_BUSY_POLL spin window in microseconds for the per-core worker socket (.EPOLL / .URING) | recvmmsg wake-up latency | set to e.g. 50 to cut wake-up latency under load | shorter spin, more idle-sleep wakeups | cores spin when idle | 0 leaves it unset, no-op without kernel SO_BUSY_POLL support |
| worker_stack_size_bytes | 524288 | worker thread stack for the per-core workers (.EPOLL / .URING) | per-thread RSS (demand-paged) | raise for deep handlers, lower to trim RSS | stack overflow in deep handlers | wasted RSS per worker | cost is low until the depth is used |
| socket_rcvbuf | 4194304 | requested SO_RCVBUF per per-core UDP socket, holds the burst arriving between recvmmsg batches | packet loss on a syscall-bound run (loss becomes retransmits) | leave high, lower only to trim memory on a tiny deployment | more dropped datagrams under burst, more retransmits | more kernel socket memory per worker | capped at net.core.rmem_max (and doubled internally), 0 leaves the kernel default |
| socket_sndbuf | 4194304 | requested SO_SNDBUF per per-core UDP socket, so a coalesced GSO send flight is not throttled | send throttling under a large flight | leave high, lower only to trim memory | a large send flight stalls on a small buffer | more kernel socket memory per worker | capped at net.core.wmem_max, 0 leaves the kernel default |
| gso_enabled | true | UDP GSO (UDP_SEGMENT): coalesce a multi-packet response flight to one peer into one sendmsg | send-path syscalls, hot | leave on, disable only to A/B or on a constrained kernel | | fewer send syscalls, lower CPU and higher throughput | probed at startup, falls back to plain sendmmsg on kernels older than 4.18 |
| tls | null (required) | TLS 1.3 context: cert, key, ALPN, QUIC needs TLS 1.3 | enables QUIC | attach a TLS 1.3 context | | | null is rejected, QUIC has no cleartext mode |
| cid_len | 8 | server-issued connection ID length in bytes (RFC 9000) | per-packet CID handling | leave at 8, fixed length enables per-core steering | shorter, fewer distinct CIDs | longer CID overhead per packet | enables future per-core CID steering |
| max_idle_ms | 30000 | connection idle timeout in ms (RFC 9000 10.1) | liveness | lower for faster reclaim of idle connections | idle connections closed sooner | idle connections linger | too low closes slow but live connections |
| max_streams | 128 | max concurrent request streams (RFC 9000 4.6) | per-conn stream state | raise for highly multiplexed clients | clients blocked sooner | more per-conn state | too low serializes a multiplexed client |
| max_datagram_size | 1200 | wire size targeted for a 1-RTT response datagram, effective size is min(this, client max_udp_payload_size, 16 KiB ceiling) | packet sizing and cwnd, hot | raise (e.g. 8192) only where path MTU is known large (loopback, jumbo LAN): fewer packets per response, so less per-packet header/AEAD/ack work (the static-h3 wall) | smaller packets, more per-packet work | fewer packets, less per-packet work, but a value above the real path MTU fragments on a WAN | never over-sends past the client's advertised limit, also the initial cwnd basis, 1200 is the QUIC minimum |
| max_stream_chunk | 0 (derive) | explicit cap on STREAM-frame payload bytes per 1-RTT packet, 0 derives it from the datagram size | bytes per packet, hot | leave 0 so raising max_datagram_size widens packets automatically | a small non-zero value forces more packets per response | a large non-zero value approaches the datagram size | 0 means datagram size minus the frame and tag room |
| max_inflight_packets | 128 | response packets in flight per connection before waiting for acks (congestion-window ceiling and loss-detection ring depth) | multi-packet response throughput, hot | raise for higher per-connection throughput on large responses | smaller send bursts, gentler on a constrained client receive buffer, lower per-conn throughput | bigger window, a large response streams in fewer ACK-clocked rounds, more send bookkeeping | clamped to the compile-time ring capacity (128 packets, connection.zig max_sent_ranges), raising past it needs that bumped and a rebuild |
| initial_window_packets | 32 | initial congestion window in packets, how much of a response goes out before the first ack (RFC 9002 7.2) | first-flight latency, hot | raise on a low-loss path so a response needs fewer ACK-clocked rounds | smaller first burst, more rounds for a big response | larger first burst, fewer rounds, risk of loss and bufferbloat on a real lossy network | effective first burst is min of this, max_inflight_packets, and the ring capacity |
| logger | null | optional logger for lifecycle lines | | attach for logging | | | |

## FIX (`FixServerConfig`)

| field | default | controls | perf impact | how to tweak | if lower | if higher | knob consequence |
| :- | :- | :- | :- | :- | :- | :- | :- |
| io | required | std.Io backend | | | | | |
| ip | required | bind address | | | | | |
| port | required | bind port, non-zero | | | | | zero is rejected |
| comp_id | required | server SenderCompID (tag 49) | | | | | required for the FIX session |
| dispatch_model | required | concurrency model | picks the strategy | `.EPOLL`/`.URING` on Linux for scale | | | non-Linux folds to `.POOL` |
| kernel_backlog | 1024 | TCP listen backlog | kernel accept queue | raise under storms | dropped connections | more kernel memory | too low drops connections |
| uring_send_buf_size | 65536 | per-connection send buffer for the .URING dispatch model | per-conn memory under .URING | raise for larger replies, lower to shrink per-conn memory | more buffer growth on big replies | more memory per connection | no effect under other dispatch models |
| uring_max_conns_per_worker | 65536 | max concurrent connections one .URING worker tracks (fd-indexed slab) | per-worker slab, demand-paged | raise for very high concurrency, lower to shrink the slab | connections rejected past the cap | larger upfront slab (demand-paged) | only the .URING model |
| default_heartbeat_secs | 30 | default HeartBtInt (seconds) echoed in the Logon response when the client omits tag 108 | not perf, session liveness | raise to reduce heartbeat traffic, lower for faster dead-peer detection | more heartbeat messages | slower dead-session detection | only used when the client omits tag 108 |
| workers | 0 | accept/event-loop workers, 0 = cpu_count | parallelism | leave 0 (auto) | fewer cores | context-switching | ignored by `.ASYNC` |
| pool_size | 0 | pool thread count, 0 = max(10, cpu*2) | `.POOL` concurrency | raise for blocking handlers | queueing | more threads | only used by `.POOL` |
| worker_stack_size_bytes | 524288 | worker thread stack for the .EPOLL and .URING handler threads | per-thread RSS (demand-paged) | raise for deep handlers, lower to trim RSS | stack overflow in deep handlers | wasted RSS per worker | cost is low until the depth is used |
| pool_stack_size_bytes | 262144 | pool worker thread stack for the .POOL model, smaller because FIX handlers process small fixed-format messages | per-thread RSS under .POOL | raise if a pool handler needs more, lower to trim RSS | stack overflow in a deep pool handler | wasted RSS per pool thread | only used by .POOL |
| heartbeat_timeout_ms | 0 | ms before sending TestRequest, then Logout on no reply, 0 = disabled | session liveness | lower for faster dead-session detection | more heartbeat traffic, faster detection | slower to detect dead sessions | only takes effect after Logon |
| conn_timeout_ms | 0 | idle close in ms when heartbeat is off, 0 = disabled | session liveness | set when not using heartbeats | connections closed sooner | idle sessions linger | no TestRequest is sent before closing |
| handler_timeout_ms | 0 | per-message handler budget in ms, 0 = disabled | cooperative deadline | set to bound slow handlers | handlers cut sooner | slow handlers run longer | per-route Route.timeout_ms overrides this |
| logger | null | optional logger, lifecycle plus per-message session() | | attach for logging | | | |

## UDS (`UdsServerConfig`)

| field | default | controls | perf impact | how to tweak | if lower | if higher | knob consequence |
| :- | :- | :- | :- | :- | :- | :- | :- |
| io | required | std.Io backend | | | | | |
| path | required | filesystem path for the socket file (max 107 bytes) | | | | | unlinked before bind and at exit |
| allocator | required | backing allocator | | | | | |
| kernel_backlog | 128 | listen backlog before accept() | kernel accept queue | raise under storms | dropped connections | more kernel memory | too low drops connections |
| max_recv_buf | 4096 | max payload bytes per frame, over-size closes the connection | per-conn memory and max frame | raise for larger frames | large frames close the connection | more memory per connection | too low closes valid large frames |
| recv_timeout_ms | 0 | socket receive timeout (SO_RCVTIMEO), 0 = disabled | blocks recv past this | set to drop stalled peers | peers dropped sooner | slow peers tolerated | 0 waits indefinitely |
| send_timeout_ms | 0 | socket send timeout (SO_SNDTIMEO), 0 = disabled | blocks send past this | set to drop slow consumers | consumers dropped sooner | slow consumers tolerated | 0 waits indefinitely |
| logger | null | optional logger for lifecycle lines | | attach for logging | | | |

## TLS context (`Tls.Context.Config`)

Server-side TLS policy, validated once at init. Attach the built `Tls.Context` by pointer to an engine's `tls` field. Omitting the optional fields yields the secure default (forward secrecy, AEAD, ECDHE-only).

| field | default | controls | perf impact | how to tweak | if lower | if higher | knob consequence |
| :- | :- | :- | :- | :- | :- | :- | :- |
| cert_path | required | PEM path to the end-entity certificate (ECDSA P-256, Ed25519, or RSA) | startup load | | | | required |
| key_path | required | PEM path to the private key matching cert_path | startup load | | | | required, must match the cert |
| alpn | empty | ALPN protocols offered, in server-preference order | handshake | set `.{ .HTTP_1_1 }` for Http1, `.{ .H2 }` for Http2 | | | browsers need ALPN h2 for HTTP/2 over TLS |
| min_version | `.TLS_1_2` | version floor, valid range TLS 1.2 to 1.3 | handshake compatibility | raise to `.TLS_1_3` to require 1.3 | | | 1.0/1.1 are never offered (RFC 8996) |
| max_version | `.TLS_1_3` | version ceiling | handshake | lower only for legacy interop | | | a 1.2 ceiling rejects 1.3 |
| curves | default ECDHE set | ECDHE curves in preference order | handshake key exchange | reorder for client compatibility | | | an unsupported value (P384, MLKEM768) is rejected at init |
| ciphers | default AEAD set | AEAD cipher suites in preference order, 1.3 and 1.2 | handshake | reorder for client compatibility | | | an unsupported value (AES_256, CHACHA20, any RSA suite) is rejected at init |
| prefer_server_ciphers | true | honor server cipher order over the client's | handshake selection | leave on for predictable selection | | | with the single-suite set the choice is identical either way |
| hsts_max_age_s | 0 | HSTS max-age in seconds (RFC 6797), 0 = off | one response header | set to enable Strict-Transport-Security | | | a long value pins clients to https |

## Logger (`Logger.Config`)

Build one Logger with this config and attach it by pointer to any engine's `logger` field. Most of the Logger's sizing is compile-time. The one runtime knob is the file write-buffer.

| field | default | controls | perf impact | how to tweak | if lower | if higher | knob consequence |
| :- | :- | :- | :- | :- | :- | :- | :- |
| console | `.OFF` | console output mode | | set to enable console output | | | |
| console_min_level | `.INFO` | minimum level for console output | | raise to quiet the console | | | |
| save_path | "" | directory for log files, empty disables file logging | disk I/O when set | set to enable file logging | | | the directory must already exist |
| save_file | "log" | base name for log files | | set the file base name | | | |
| save_min_level | `.INFO` | minimum level for file output | | raise to log fewer lines to file | | | |
| max_lines | 1000000 | lines per file before rotating to the next sequence number | rotation frequency | raise for fewer, larger files | more frequent rotation | larger files | |
| write_buf_size | 65536 | file write-buffer size in bytes, batches log lines per write() to disk | log write() batching | raise to cut disk syscalls, lower to bound memory | more frequent flushes | larger buffered loss window on crash | minor |

## Notes

- Required fields (`io`, `ip`, `port`, `allocator`, `path`, `comp_id`, `cert_path`, `key_path`) have no default and must be set. A zero `port` is rejected at init.
- `io`, `logger`, and `tls` are caller-owned: they are passed by handle or pointer and must outlive the server.
- `.EPOLL` and `.URING` are Linux-only. Off Linux they fold to `.POOL` (HTTP/2 also folds to `.POOL` on Linux for the TLS path).
- The compression and response-cache features are active only under `.EPOLL` and `.URING` (shared-nothing, one owner per worker).
