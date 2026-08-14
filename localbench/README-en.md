# localbench

> Bahasa Indonesia: [`README-id.md`](README-id.md)

Each directory here is one standalone zig server that depends on this checkout by path, so
building an entry builds the local zix source. Three scripts wrap it: build, validate, run.

Run every command from the repository root.

<br>

## Quick run

The three steps in order, for a run whose numbers you intend to quote:

```bash
./scripts/localbench-build.sh all --release fast
./scripts/localbench-validate.sh http1-uring
sudo -E ./scripts/localbench-isolate.sh http1-uring --probe --sample-mem --summarize
```

Each step is explained below.

<br>

## What you need

| Tool | Needed for |
| :- | :- |
| `zig-0.16` | building an entry (set `ZIG_BIN` to point at another one) |
| `openssl` | the self-signed certificate the TLS profiles use |
| `unzip` | extracting `static.zip` when there is no fixtures checkout |
| `docker` | the postgres and redis sidecars, and the HTTP/3 load generator |
| `gcannon` `wrk` `h2load` `ghz` | the load generators, one per profile family |
| `grpcurl` | the gRPC checks in step 2 |

A missing load generator skips the profiles that need it, it does not fail the run. The
HTTP/1.1 profiles need `gcannon` only.

Fixtures (dataset, static set, request templates) are read out of an HttpArena checkout,
nothing is copied into this repository. The default location is a sibling `HttpArena`
directory next to this one, and any script takes another path as its last argument. Without
a checkout the build offers the tracked `static.zip` instead, which covers the static
profiles and nothing else.

<br>

## Step 1: build

```bash
./scripts/localbench-build.sh --list                # entries that have sources
./scripts/localbench-build.sh http1-uring           # one entry
./scripts/localbench-build.sh all --release fast    # every entry, release build
./scripts/localbench-build.sh http1-uring /path/HttpArena
```

Debug is the default, matching how zix builds elsewhere. `--release` takes the mode:
`debug`, `fast`, `safe`, or `small`. Use `--release fast` for any run whose numbers you
intend to quote.

This step also generates `certs/server.crt` and `certs/server.key` if they are absent, and
points `data/` at the fixtures. Neither is committed.

<br>

## Step 2: validate

```bash
./scripts/localbench-validate.sh http1-uring
./scripts/localbench-validate.sh http1-uring json    # one profile
```

Every endpoint the entry's `meta.json` subscribes to gets a PASS or a FAIL. A wrong answer
makes the matching number in step 3 meaningless, so clear this first.

<br>

## Step 3: run

```bash
./scripts/localbench-run.sh http1-uring          # every profile in meta.json
./scripts/localbench-run.sh http1-uring json     # one profile
sudo ./scripts/localbench-run.sh http1-uring --quiesce --probe --save --summarize
```

The default is a dry run: 3 passes per connection count, 5 seconds each, the best pass
wins, nothing written under `results/`. The server is always pinned to one half of the
machine and the load generator to the other, so neither side measures the other's stalls.

| Flag | What it does |
| :- | :- |
| `--runs N` | passes per connection count, best wins (default 3) |
| `--duration SPEC` | length of one pass (default 5s) |
| `--load-threads N` | override the derived load generator thread count |
| `--quiesce` | hold the host knobs still for the run, needs root, restored on exit |
| `--probe` | refuse to measure when the box varies by more than 1 percent |
| `--sample-mem` | poll the server's memory into a side file during the run |
| `--save` | write `results/<profile>/<conns>/<entry>.json` |
| `--summarize` | end with a markdown table instead of the aligned text one |

`./scripts/localbench-isolate.sh <entry>` is the same run with the host knobs applied for
you, saved before and restored on exit. Every flag in the table above works there too,
forwarded exactly as typed and never added on your behalf:

```bash
sudo -E ./scripts/localbench-isolate.sh http1-uring json --probe --sample-mem --summarize
```

The HTTP/3 profiles need one image, built from the arena checkout:

```bash
docker build -t h2load-h3:local -f docker/h2load-h3.Dockerfile docker
```

<br>

## Step 4: read the result

The full transcript is written to `logs/localbench/run-<entry>-<stamp>.txt`, and the path
is printed on the last line of the run. `--save` adds one json file per tier under
`logs/localbench/results/`, and `--sample-mem` adds the memory log beside it.

With `--summarize` the run ends in a table:

| Test | Conn | RPS | CPU | Mem |
| :- | :- | :- | :- | :- |
| baseline | 512 | 4,187,491 | 6366.9% | 134MiB |
| static | 4096 | 2,022,455 | 5491.0% | 191MiB |

Reading it:

| Column | Meaning |
| :- | :- |
| RPS | successful responses over the measured duration, not the driver's own throughput line |
| CPU | percent of ONE core, so 6366.9% is 63.7 cores |
| Mem | peak of the per-snapshot sum across the server processes |

All three numbers come from the same pass, the one that produced the best throughput.

<br>

## Entries

```
gateway-async     gateway-epoll     gateway-uring
http1-async       http1-epoll       http1-uring
http1-ws-async    http1-ws-epoll    http1-ws-uring
http2-async       http2-epoll       http2-uring
http2-grpc-async  http2-grpc-epoll  http2-grpc-uring
http3-async       http3-epoll       http3-uring
```

An entry serves only what its `meta.json` lists, so a profile name that is not in that list
is rejected rather than measured. Each entry has its own `README.md` describing what it
caches and what it does not.
