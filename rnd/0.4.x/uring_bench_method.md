# io_uring .URING benchmark method (ADR-037 Phase 3)

How each number in `uring_phase3_results.txt` (and later lever results) is
produced. Read this first, then the results files.

## Host constraints (why the method is shaped this way)

- `perf_event_paranoid = 2`: unprivileged perf can count USERSPACE events on its
  own processes (`:u` suffix), but NOT kernel-mode cycles. So `cycles` (user +
  kernel) is unavailable; only `cycles:u` is. This matters because io_uring's
  main win is kernel-side (fewer syscall transitions), invisible to `:u`.
- `RLIMIT_MEMLOCK = 8 MB`, not raisable in this shell. gcannon (the pipelining
  io_uring load client) needs unlimited memlock, so it is UNUSABLE here. The
  ring server itself fits in 8 MB (12 workers ran fine). Load tool is wrk only.
- Tools present: wrk, perf, taskset, curl. gcannon present but unusable.

## Servers under test

Same `zix.Http1` engine, dispatch model is the only variable, identical routes
(`GET /` -> "Hello, World!"):
- `.EPOLL`  : `examples/http1_basic_4_epoll.zig`
- `.URING`  : `examples/http1_basic_5_uring.zig`

Build with plain `zig build` (installs to `zig-out/bin/`, does NOT run). Then RUN
THE BINARY DIRECTLY (`/tmp/srv_x &`), never `zig build example-x` (that is a
RunArtifact step: it builds AND runs, blocking the shell on the server). Copy the
installed binary to a stable path per variant so an A/B compares fixed binaries.

## Load

`wrk -t6 -c512 -d10s` against `http://127.0.0.1:9100/`.
- p1  (pipeline depth 1): plain wrk, HTTP keep-alive, one in-flight request per
  connection.
- p16 (pipeline depth 16): `wrk -s rnd/0.4.x/uring_pipeline`, which formats 16
  GETs into one socket write so each connection carries a depth-16 burst.

Run each variant 2-3 times, INTERLEAVED (A,B,A,B,...) so machine drift hits both
sides equally. Fresh server process per run, killed and port-drained between runs.

## Metrics (what and how)

1. Throughput, `rps`
   - What: requests/sec the server sustains.
   - How: parse `Requests/sec:` from wrk output.
   - Note: loopback is kernel/client bound, so this is near-parity across models.
     It is a sanity/parity check, NOT the discriminator.

2. Total server CPU per request, `cpu/req` (THE discriminator)
   - What: CPU seconds the server process burns per request, user + KERNEL.
   - How: read `/proc/<server_pid>/stat` fields utime(14) + stime(15) in clock
     ticks just before and just after the wrk window, divide the delta by
     `getconf CLK_TCK`, then divide by wrk's total request count.
     `cpu/req_us = (d_utime + d_stime) / CLK_TCK * 1e6 / requests`.
   - Why this one: it INCLUDES kernel time, so it captures the io_uring
     syscall-batching effect that `cycles:u` cannot. utime+stime aggregates all
     worker threads of the process. At parity throughput, lower cpu/req = the win.

3. L1 data-cache misses per request, `l1miss/req`
   - What: userspace L1 dcache load misses per request (cache locality).
   - How: `perf stat -e L1-dcache-load-misses:u -p <server_pid> -- sleep <window>`
     running in parallel with wrk, then count / requests.
   - Why: hardware userspace event, allowed at paranoid=2. URING shows fewer here
     (hotter caches), the clearest measurable URING-vs-EPOLL difference so far.

4. (optional) Userspace cycles per request, `cyc/req:u`
   - How: `perf stat -e cycles:u -p <pid>` / requests.
   - Note: near-parity URING vs EPOLL, because the dispatch difference is
     kernel-side. Kept only to show the win is NOT in userspace cycles.

## What cannot be measured here

- Total (user+kernel) cycles and kernel-only cycles: blocked by paranoid=2. Use
  `cpu/req` (from /proc) as the kernel-inclusive proxy instead.
- gcannon-style native io_uring pipelining: blocked by the 8 MB memlock cap.

## Harness

- `rnd/0.4.x/uring_pipeline.lua` : the wrk depth-16 script (see "Can the lua be
  replaced?" below).
- The `measure()` bash function is inline in the run command (not a committed
  script): start server, wait for listen, warmup curl, sample /proc CPU + perf
  around a 10s wrk run, kill, parse. Reproduce from this note if needed.
- PITFALL: never `pkill -f '<pattern>'` where `<pattern>` also appears in your own
  running command line (e.g. the binary path you are scripting around) - pkill
  matches and kills your own shell. Kill tracked PIDs instead.

## Can the wrk lua script be replaced?

Yes. The lua only exists to make wrk do HTTP/1 PIPELINING (wrk has no native
pipeline flag). For depth 1 no script is needed at all. Alternatives:
- gcannon `-p <depth>`: native pipelining, no lua. BEST tool, but UNUSABLE on this
  host (memlock). Use it where memlock can be raised (`ulimit -l unlimited`).
- `rnd/0.4.x/client_hello.zig`: the in-repo closed-loop pipelining client from the
  PoC (`-c/-t/-d/-p` flags), no lua, no memlock issue. A drop-in wrk+lua
  replacement once pointed at :9100, and keeps the harness dependency-free.
- A bespoke client (raw sockets writing N pipelined GETs).
On THIS box the practical pick is wrk + the lua for p16 and plain wrk for p1;
client_hello.zig is the lua-free fallback if wrk/lua is undesirable.
