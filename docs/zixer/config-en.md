# zixer Config Reference

Everything an operator can control in zixer lives in two kinds of plain text file: one `main.cfg` for the daemon, and one `.cfg` per site. There is no other input, no environment tuning, and no command flag that changes serving behavior. This page lists every key, its default, what it actually does today, and how to check it on your own machine.

Read `how-to-use-en.md` first if you have not started a site yet. The internals behind each key are in `lld-en.md`.

<br>

## The two files

```
~/.zixer
|
|___/sites
|   |___example.cfg.sample             (written by init, inert)
|   |___my_service.cfg                 (one site per file)
|
|___/logs
|
|___main.cfg
|___control.sock                       (created by the daemon while it runs)
```

| file | who reads it | when |
| :- | :- | :- |
| `main.cfg` | the daemon, once at start | `zixer daemon`, or the auto-spawn behind the first `zixer start` |
| `sites/<name>.cfg` | the daemon, per site | every `start` and `restart` of that site |

The root dir resolves in a fixed order: `--dir <path>`, then the `ZIXER_DIR` environment variable, then `$HOME/.zixer` (`%USERPROFILE%\.zixer` on Windows). A bare `zixer` prints which one answered and whether that root is initialized.

A site file name is the site identity. Only files ending `.cfg` are loaded, which is why the sample ships as `example.cfg.sample`.

<br>

## Value syntax

Both files use the same flat grammar.

| form | meaning |
| :- | :- |
| `key: value` | one setting per line, spaces around the colon are trimmed |
| `# text` | comment, whole line |
| `port: 8080  # edge port` | comment, trailing |
| `tls_cert: C:/certs/full.pem` | only the first colon splits, so a path keeps its own |
| `upstreams: a:1, b:2` | comma list, items are trimmed |
| `max_recv_buf: 16 * 1024` | integer math, see below |
| `tls: true` | boolean, only `true` and `false` |

Numeric values accept integer arithmetic with `+ - * /` and parentheses, multiply and divide binding first, left to right. Division must come out exact: `10 / 4` is refused rather than silently truncated, because a remainder usually means a typo. The result must fit 64-bit math.

Anything the grammar cannot read is a fault, never a silent skip:

| written | reported as |
| :- | :- |
| `no colon here` | `line 9 has no ':', write key: value` |
| `: 8080` | `line 3 has no key before ':'` |
| `port:` | `line 4 has no value after ':'` |
| `wrokers: 2` | `unknown key, remove it or fix the typo` |
| a key twice | `duplicate key, keep one line` |

<br>

## main.cfg

| key | default | controls | applies | if wrong |
| :- | :- | :- | :- | :- |
| workers | `1` | accept loops each site runs, `0` means every available thread | http1, http2, and grpc sites that serve upstreams or a `public_dir` | above the thread count this process may use it faults and stays at the default |
| dispatch | `async` | dispatch model: `async`, `epoll`, `uring` | reported only, see below | `epoll` and `uring` fault off Linux, any other word faults everywhere |
| logs_dir | `<root>/logs` | where log output will be written | the directory must exist, nothing writes into it yet | a missing directory faults and `status` exits 1 |
| sites_dir | `<root>/sites` | where site `.cfg` files are read from | every `list`, `status`, `start`, and `restart` | a missing directory faults, and no site is found |
| kernel_backlog | `1024` | default listen queue length for tcp site listeners | http1, http2, and grpc sites without their own value, plus the acme companion listener | `0` faults, the kernel still caps the value at `net.core.somaxconn` |
| max_recv_buf | `8192` | bytes one per-connection stream buffer gets, see below | http1, http2, grpc, and TLS sites, as the default a site file may override | outside `1024` to `262144` it faults and stays at the default |
| process_limit | `0` | requests one site may run upstream at once, `0` turns the gate off, see below | every proxied site, as the default a site file may override | above `65536` it faults and stays at the default |
| process_queue_len | `0` | requests that may wait for a slot, `0` refuses instead of queueing | with `process_limit` above `0` | above `65536` it faults, and a value above `0` with `process_limit: 0` faults |
| process_queue_timeout_ms | `6000` | how long one request waits before the edge answers 504 | with `process_queue_len` above `0` | outside `1` to `600000` it faults and stays at the default |
| public_dir_cache_ttl_ms | `0` | how long a served file stays cached, `0` turns the cache off, see below | every site with a `public_dir`, as the default a site file may override | above `3600000` it faults and stays at the default |
| public_dir_cache_max_entries | `256` | files the cache may hold open, daemon-wide | the one cache table this daemon builds | `0` or above `1048576` faults and stays at the default |

Only `dispatch` is validated without being applied. A blank `main.cfg` is valid: every key falls back to the defaults above.

### What workers does

A started tcp site runs `workers` accept loops instead of one. Each loop holds
its own listener on the site's port, and the kernel hands each of them a share
of the arriving connections, so accepting stops being one thread's job.

- `workers: 0` means every thread this process may run on. On Linux that is read from the process affinity mask, so a daemon pinned to a cpuset gets the cores it was given, not the ones the machine has. A container limited by a cpu quota rather than a cpuset should name a count instead. This is what `zixer init` writes, and the default above is what an absent key falls back to.
- Each loop also owns its own upstream pool and idle connection cache. The site's idle bound is divided between them, so a backend never loses more of its capacity because the edge runs more loops.
- `zixer status` prints the resolved count beside the configured one whenever they differ, i.e. `workers: 0 (resolved to 12)`.
- The count is read once, when the daemon starts. Editing `main.cfg` and restarting a single site does not change it, the daemon has to be restarted.
- Windows keeps one loop whatever the count says. Two listeners cannot share a port there: the second bind takes the port over instead of joining it, so the extra loops would serve nothing.
- Only the tcp proxy engines spend it. An http3 site and a udp site each own one socket whose per-connection state is keyed to that socket.

More loops help when accepting is the wall, which is many connections rather
than many requests on a few. Measured on this project's demo static site,
12 loops against 1: no change at 8 connections, 8 percent at 1024, and 61
percent at 4096.

### What max_recv_buf does

Every accepted connection allocates its stream buffers when it starts and
releases them when it ends. `max_recv_buf` is the size of one such buffer,
and how many a connection holds depends on what the site does:

| site shape | buffers per connection | at the `8192` default |
| :- | :- | :- |
| static only, `public_dir` and no `upstreams` | 2, the client read and write | 16 KiB |
| proxied, any engine | 4, the client pair and the upstream pair | 32 KiB |
| grpc | 2 for the client, plus 2 per upstream h2 connection actually opened | 32 KiB with one upstream |

The size does not limit anything: a site on the smallest value still parses a
full request head, still serves a file of any length, and still forwards a
body of any length. It only decides how much moves per read and per write, so
a smaller value costs more syscalls per large transfer and a larger one costs
resident memory on every open connection.

- A site file may name its own `max_recv_buf`, which overrides this one for that site.
- The range is `1024` to `262144` bytes on both, and a value outside it faults rather than being clamped silently.
- This is not the whole per-connection cost. A proxied http1 connection also holds three head buffers of 16 KiB each, which are protocol limits rather than a tuning choice, and a TLS connection adds about 58 KiB for the record and plaintext buffers of its session.

Measured on this project's demo static site, resident memory per held
connection: 62.7 KiB at `1024`, 64.7 KiB at `2048`, 76.7 KiB at `8192`, and
124.7 KiB at `32768`. The proxied site is 112.7, 116.8, 140.8, and 236.8 KiB
at the same four values.

### What the process gate does

The three `process_` keys are one overload valve. `process_limit` is how many
requests a site may have running against its backends at any moment,
`process_queue_len` is how many more may wait for a free slot, and
`process_queue_timeout_ms` is how long one of them may wait.

Past both, the edge answers:

```
HTTP/1.1 504 upstream queue full
Proxy-Status: zixer; error="connection_limit_reached"
```

and a request that waited its whole budget gets `504 upstream queue timeout`
with the same `Proxy-Status`.

Size `process_limit` by what the backend can absorb, not by what this machine
can run. That is why the count is per site and shared by every worker: with
`workers: 0` the loop count follows the machine's thread count, and the
backend does not care how many threads zixer happens to have.

- `0` is the gate off, and is the default. A site that never sets it behaves exactly as it did before the keys existed.
- `process_limit` with `process_queue_len: 0` is a valid choice: run this many, refuse the rest at once. That sheds load in microseconds instead of holding connections open.
- `process_queue_len` above `0` with `process_limit: 0` is refused, because without a limit nothing ever queues and the line would silently do nothing.
- The range is `0` to `65536` for both counts, and `1` to `600000` ms for the wait.
- A site file may name any of the three, and each one falls back to the main.cfg value on its own.
- A static request never enters the gate. It has no backend to spend, so `public_dir` keeps answering at full rate while the proxy plane is saturated.

Where a request gives its slot back depends on how long its exchange lives:

| engine | slot held until |
| :- | :- |
| http1 | the response is fully relayed |
| http2 | that stream's response is fully relayed |
| http3 | that stream's response is fully relayed |
| grpc | the request block reaches the upstream, the stream then runs outside the gate |
| websocket | the 101 is relayed, the tunnel then runs outside the gate |

A websocket tunnel and a grpc stream live as long as their client, so they
release at handover. Holding a slot for a whole tunnel would let a handful of
open sockets pin the site's capacity with the backend sitting idle.

grpc differs one more way: it never queues. Its frame loop pumps every live
stream on the connection, so parking it to wait would stall work already
running. At the limit a new grpc stream gets a trailers-only `UNAVAILABLE`,
which is what a grpc client retries on.

### What the public_dir cache does

With `public_dir_cache_ttl_ms: 0`, the default, every static request opens the
file, stats it, reads it, and closes it. A browser makes that worse than it
looks: it sends `Accept-Encoding: gzip, deflate, br`, so zixer looks for a
`.br` sibling, then a `.gz` sibling, then the file itself. Against a file with
no precompressed sibling that is three opens for one response.

Above `0`, the file is kept open, its siblings are resolved once when the entry
is built, and the next request for it is a table lookup. There is one table per
daemon, shared by every site and every worker, so a file costs one descriptor
for the whole process rather than one per accept loop. On a `workers: 0`
machine that difference is the thread count.

**When it is worth turning on**

| your situation | turn it on |
| :- | :- |
| a built front-end bundle, many files, mostly unchanged between deploys | yes, this is what it is for |
| files served to real browsers, so `Accept-Encoding` is always present | yes, it removes two speculative opens per request |
| large files, tens of KB and up | yes, and see the note on large bodies below |
| files regenerated constantly, faster than any window you would accept | no, every entry would be stale before it is used |
| one or two tiny files and nothing else | barely, the page cache already makes those opens cheap |

**What it costs**

- One descriptor per cached variant. `public_dir_cache_max_entries` bounds the count, and the table clamps itself to a quarter of the process descriptor limit regardless, so it cannot starve the sockets.
- Staleness. The window is also how long an edited file keeps serving its old bytes. A deploy shows up within one window with no restart, so pick a window you would accept as deploy lag: seconds for a machine people edit by hand, longer for one that only changes on release.

Nothing about it can fail a request. A full table, an unreadable file, or a
path too long to store all fall through to the uncached open, which is also
what produces the 404.

**Large bodies leave a different way**

On a cleartext Linux http1 site, a body of 64 KB or more is handed to the
kernel and never enters zixer's memory. Under that size the body is written
together with its own head in one go, which is cheaper than a separate
syscall on its own segment. This is automatic and there is no key for it.

A TLS site never takes that path, because the bytes have to be encrypted. An
http2 or http3 site does not either, since every byte has to be framed. Those
sites still get everything the table itself buys.

**What it measured**

A 12 core machine, a 20 file front-end bundle with `.br` and `.gz` siblings,
`h2load` at 8 connections, both builds unoptimized:

| workload | off | on |
| :- | :- | :- |
| the whole bundle, browser `Accept-Encoding` | 100,066 req/s | 113,666 req/s |
| the whole bundle, no `Accept-Encoding` | 81,162 req/s | 105,559 req/s |
| one 67 KB file with a `.br` sibling | 65,996 req/s | 97,319 req/s |
| one 22 KB file with no sibling | 86,664 req/s | 115,679 req/s |
| one 307 KB file, uncompressed | 24,189 req/s | 59,661 req/s |

The 307 KB row is the kernel path, not the table. Read these as the shape of
the win, not as rates to plan around: they are debug builds on a machine that
was doing other work, and at 512 connections the same row on the same build
varied between 63,704 and 99,173 req/s, which is wider than the effect.

### Keys that are validated but not applied yet

`dispatch` is parsed, range-checked, and printed by `zixer status`, and nothing in the serving path reads it. `dispatch: async`, `dispatch: epoll`, and `dispatch: uring` all serve through the same edge loops, where each accept loop dispatches every connection as a concurrent task.

Treat it as reserved. It is kept because the validation is the part an operator needs first (a config that will be honored later must still be refused now when it is wrong), but do not size a machine around it.

<br>

## Site config

One file, one site. `engine` and `port` are required, everything else has a default or is optional.

| key | default | controls | engines | if wrong |
| :- | :- | :- | :- | :- |
| engine | required | which edge serves the site: `http1`, `http2`, `grpc`, `http3`, `udp` | all | missing or unknown faults, and the site never binds |
| ip | `0.0.0.0` | bind address, IPv4 or IPv6 literal | all | anything that is not an address literal faults, a hostname is not accepted |
| port | required | edge port | all | outside 1 to 65535 faults, a port another started site owns is refused at `start` |
| tls | `false` | terminate TLS at the edge | http1, http2, grpc, required on http3, refused on udp | a non boolean faults |
| tls_cert | none | certificate chain path, PEM | with `tls: true` | required when tls is on, refused when it is off, a missing file faults in `status` and refuses the `start` |
| tls_key | none | private key path, PEM | with `tls: true` | same as `tls_cert` |
| acme_webroot | none | directory served under `/.well-known/acme-challenge/` | cleartext http1, or any TLS site | needs `tls: true` or an http1 site, refused on udp, cannot pair with `acme_proxy` |
| acme_proxy | none | `host:port` the challenge path is relayed to | same as `acme_webroot` | must be `host:port`, cannot pair with `acme_webroot` |
| upstreams | none | comma list of `host:port` backends, picked round-robin | all | each item must be `host:port`, the host must be an ip literal (see below), a site needs `upstreams` or `public_dir` |
| public_dir | none | directory served as static files | http1, http2, http3, refused on grpc and udp | a missing directory faults in `status` |
| public_prefix | none | path prefix bound to `public_dir`, i.e. `/assets` | with `public_dir` | must start with `/`, needs `public_dir` |
| spa_fallback | none | file served when no static file matches, i.e. `index.html` | with `public_dir` | needs `public_dir`, and needs `public_prefix` when the site also has upstreams |
| kernel_backlog | main.cfg value | listen queue length for this site | http1, http2, grpc, refused on udp, accepted but unused on http3 | `0` faults |
| max_recv_buf | main.cfg value | bytes one per-connection stream buffer gets | http1, http2, grpc, and TLS sites | outside `1024` to `262144` it faults and the site falls back to the main.cfg value |
| upstream_timeout_ms | `30000` | how long the edge waits on a silent upstream before answering 504 | http1, http2, http3, refused on grpc and udp | needs `upstreams`, `0` waits forever, above 4294967295 faults |
| process_limit | main.cfg value | requests this site may run upstream at once, `0` turns the gate off for this site | http1, http2, grpc, http3, refused on udp | needs `upstreams`, above `65536` faults |
| process_queue_len | main.cfg value | requests that may wait for a slot | same as `process_limit` | needs `upstreams`, refused on udp, and a value above `0` with `process_limit: 0` on the same file faults |
| process_queue_timeout_ms | main.cfg value | how long one request waits before the edge answers 504 | same as `process_limit` | needs `upstreams`, refused on udp, outside `1` to `600000` faults |
| public_dir_cache_ttl_ms | main.cfg value | how long a served file stays cached for this site, `0` turns the cache off for this site | http1, http2, http3, refused on grpc and udp | needs `public_dir`, above `3600000` faults |

`ip` and `port` together decide the listening socket. `0.0.0.0` binds every interface, `127.0.0.1` binds loopback only, `::` binds every IPv6 interface.

### Forwarded says how the client reached this site

Every proxied request carries a `Forwarded` header (rfc 7239) with the client address, the scheme, and the original host:

```
forwarded: for="127.0.0.1:50250";proto=https;host="localhost:9707"
```

The `proto` parameter comes from the site's own `tls` setting: `https` on a `tls: true` site, `http` on every other one, and `https` on an http3 site since quic has no cleartext transport. A backend deciding "was this request secure" can read it directly.

It is never taken from anything the client sent. An h2 or grpc caller supplies its own `:scheme` pseudo header, and a cleartext one that claims `https` would otherwise tell the backend its request arrived secure.

### Upstream hosts must be ip literals

zixer does not resolve names on the upstream leg, and the config check does not catch a name today. `upstreams: localhost:3000` passes `zixer status` and then fails when it is used:

| engine | what happens |
| :- | :- |
| http1, http2, grpc, http3 | the site starts, and every request answers `502 all upstreams failed` with `Proxy-Status: zixer; error="connection_refused"` |
| udp | the site refuses to start: `bind failed (BadUpstreamAddress)` |

Write `127.0.0.1:3000` instead of a name. An IPv6 upstream is written bare, `::1:3000`, because the value splits on its last colon. The bracketed form `[::1]:3000` passes the config check and then fails the same way a name does.

### What upstream_timeout_ms covers

The bound is on the edge waiting for the backend, not on the whole request:

| wait | bounded |
| :- | :- |
| the upstream response head, including a stall after an interim 1xx | yes |
| a `Content-Length` response body | yes |
| a chunked response body | no |
| a close-delimited response body | no |
| a websocket tunnel after the 101 | no |
| the connect to the upstream | no |

A chunked or close-delimited body carries no total byte count to end the loop on, and a server-sent-event stream is silent between events on purpose, so a deadline there would cut healthy streams. The connect has no bound because the std backend it would use panics on one.

When the head never arrives, the client gets:

```
HTTP/1.1 504 upstream timeout
Proxy-Status: zixer; error="http_response_timeout"
```

The upstream is not marked down for a timeout, and the request is not replayed against another one: it was already delivered, so replaying it could run the same work twice, and a slow backend is still a serving backend. A stall partway through a `Content-Length` body ends that response, because its head is already on the wire.

Set `upstream_timeout_ms: 0` on a site whose backend legitimately thinks for longer than the budget. That is the same unbounded wait every site had before the key existed.

<br>

## Which key applies to which engine

| key | http1 | http2 | grpc | http3 | udp |
| :- | :- | :- | :- | :- | :- |
| engine, ip, port | yes | yes | yes | yes | yes |
| tls | optional | optional | optional | required | refused |
| tls_cert, tls_key | with tls | with tls | with tls | required | refused |
| acme_webroot, acme_proxy | yes | TLS only | TLS only | yes (always TLS) | refused |
| upstreams | yes | yes | yes | yes | yes, required |
| public_dir, public_prefix, spa_fallback | yes | yes | refused | yes | refused |
| kernel_backlog | yes | yes | yes | accepted, no effect | refused |
| max_recv_buf | sizes the stream buffers | sizes the stream buffers | sizes the stream buffers | accepted, no effect | accepted, no effect |
| upstream_timeout_ms | yes | yes | refused | yes | refused |
| process_limit, process_queue_len, process_queue_timeout_ms | yes | yes | yes, setup only and never queues | yes | refused |
| public_dir_cache_ttl_ms | yes | yes | refused | yes | refused |
| public_dir_cache_max_entries | main.cfg only, one table per daemon | main.cfg only | main.cfg only | main.cfg only | main.cfg only |

"Refused" means the key faults with a fix hint and the site does not start. "Accepted, no effect" means the file validates clean and nothing reads the value.

`engine` also picks what a TLS handshake advertises: an http1 site offers `http/1.1`, an http2 site offers `h2` then `http/1.1`, a grpc site offers `h2` only.

<br>

## Cross-field rules

Every rule below is checked after the whole file is read, so one pass reports every problem at once.

| rule | fault text |
| :- | :- |
| `engine` missing | `missing, set one of http1, http2, grpc, http3, udp` |
| `port` missing | `missing, set 1-65535` |
| `tls: true` without a cert | `tls_cert: required when tls: true` |
| `tls_cert` without `tls: true` | `set tls: true or remove it` |
| neither `upstreams` nor `public_dir` | `site needs upstreams or public_dir` |
| `public_prefix` without `public_dir` | `needs public_dir` |
| `spa_fallback` without `public_dir` | `needs public_dir` |
| `public_dir_cache_ttl_ms` without `public_dir` | `needs public_dir` |
| `spa_fallback` with upstreams but no prefix | `needs public_prefix when upstreams are set` |
| `acme_webroot` and `acme_proxy` together | `choose acme_webroot or acme_proxy, not both` |
| acme keys on a cleartext http2, grpc, or http3 site | `needs tls: true or an http1 site` |
| `engine: http3` without tls | `tls: http3 requires tls: true` |
| `public_dir`, `public_dir_cache_ttl_ms`, or `upstream_timeout_ms` on a grpc site | `not supported on grpc sites, remove it` |
| `upstream_timeout_ms` on a site with no upstreams | `needs upstreams` |
| `tls` on a udp site | `udp forward is blind bytes, tls does not apply` |
| `public_dir`, `public_dir_cache_ttl_ms`, `kernel_backlog`, `upstream_timeout_ms`, the `process_` keys, or acme keys on a udp site | `does not apply to udp sites, remove it` |
| `public_dir_cache_max_entries` in a site file | `set it in main.cfg, the cache table is one per daemon and every site shares it` |
| any `process_` key on a site with no upstreams | `needs upstreams` |
| `process_queue_len` above `0` while `process_limit` is `0` | `needs process_limit above 0, otherwise nothing ever queues` |

The `spa_fallback` prefix rule exists so a backend miss never disappears into the fallback page: without a prefix bound to the static plane, every 404 from an upstream would answer as the app shell instead.

Paths are checked for existence too. `tls_cert`, `tls_key`, `public_dir`, and `acme_webroot` each fault when the path is not on this machine, and relative paths resolve against the directory the daemon runs in, not against the root dir.

<br>

## Reading a status report

```
$ zixer status
# /srv/zixer/main.cfg
main.cfg:
status: ok
workers: 1
dispatch: async
logs_dir: /srv/zixer/logs
sites_dir: /srv/zixer/sites
max_recv_buf: 8192
kernel_backlog: 1024
process_limit: 0 (gate off)
public_dir_cache_ttl_ms: 0 (cache off)

# /srv/zixer/sites/api.cfg
api.cfg:
status: error
engine: http1
ip: 0.0.0.0
port: 8080
tls: false
errors:
    upstreams: site needs upstreams or public_dir
```

`status: ok` on every block means exit code 0. Any `errors:` block means exit code 1, which is what a deploy script should gate on. A site with errors is refused at `start` with a pointer back to `zixer status <name>`.

<br>

## Worked examples

Plain reverse proxy:

```
engine: http1
ip: 0.0.0.0
port: 8080
upstreams: 127.0.0.1:3000, 127.0.0.1:3001
```

Static single page app, no backend. A built bundle changes only on deploy, so
a long window costs nothing and every file stays open between requests:

```
engine: http1
ip: 0.0.0.0
port: 8080
public_dir: /var/www/app/dist
spa_fallback: index.html
public_dir_cache_ttl_ms: 60000
```

Static assets beside a proxied backend. Only `/assets/...` comes off disk, everything else goes upstream:

```
engine: http1
ip: 0.0.0.0
port: 8080
upstreams: 127.0.0.1:3000
public_dir: /var/www/app/dist
public_prefix: /assets
```

TLS terminated at the edge, cleartext to the backend, with the renewal path served from disk:

```
engine: http1
ip: 0.0.0.0
port: 443
tls: true
tls_cert: /etc/letsencrypt/live/example.com/fullchain.pem
tls_key: /etc/letsencrypt/live/example.com/privkey.pem
acme_webroot: /var/www/acme
upstreams: 127.0.0.1:3000
```

A TLS site off port 80 also binds port 80 for the challenge, so the process needs the privilege to bind it.

gRPC, h2 end to end so trailers survive:

```
engine: grpc
ip: 0.0.0.0
port: 50051
upstreams: 127.0.0.1:9109
```

HTTP/3, TLS is not optional:

```
engine: http3
ip: 0.0.0.0
port: 443
tls: true
tls_cert: /etc/letsencrypt/live/example.com/fullchain.pem
tls_key: /etc/letsencrypt/live/example.com/privkey.pem
upstreams: 127.0.0.1:3000
```

Blind datagram forward, one flow per client, which is what a media relay in front of a WebRTC engine needs:

```
engine: udp
ip: 0.0.0.0
port: 3478
upstreams: 127.0.0.1:9083
```

Tighter listen queue on one busy site, leaving the rest on the main.cfg default:

```
engine: http1
ip: 0.0.0.0
port: 8080
upstreams: 127.0.0.1:3000
kernel_backlog: 128
```

<br>

## Checking a key yourself

Every claim on this page can be checked on a running daemon. These are the checks used to write it.

Listen queue length, the `Send-Q` column of a listening socket is the backlog:

```bash
zixer --dir /srv/zixer start api.cfg
ss -ltn | grep 8080
```

Bind address:

```bash
ss -ltn | grep 8080      # 0.0.0.0:8080 or 127.0.0.1:8080 as configured
```

Port ownership between two sites:

```bash
zixer --dir /srv/zixer start other.cfg
# other.cfg port 8080 is already used by api.cfg
```

A config edit takes effect on `restart`, which re-reads the file from disk:

```bash
zixer --dir /srv/zixer restart api.cfg
```

Static plane against the proxy plane on a site with `public_prefix`:

```bash
curl -s http://127.0.0.1:8080/assets/app.css   # from public_dir
curl -s http://127.0.0.1:8080/                 # from the upstream
```

Certificate name gate on a TLS site. The certificate decides which Host values the site answers, everything else gets 421:

```bash
curl -sk https://localhost:8443/               # 200
curl -sk --resolve other.test:8443:127.0.0.1 https://other.test:8443/   # 421
```

Renewal path from the webroot:

```bash
echo token-body > /var/www/acme/.well-known/acme-challenge/tok123
curl -s http://127.0.0.1:8080/.well-known/acme-challenge/tok123
```

<br>

## Notes

- A config change never applies to a running site by itself. `restart <site.cfg>` re-reads one site file, and `main.cfg` is read once per daemon, so changing it needs `daemon stop` and a fresh start.
- The daemon holds the control socket at `<root>/control.sock`. The whole path must fit the platform limit for unix sockets (108 bytes on Linux), so a deep root dir is refused with `control socket path is too long for this platform`.
- Site files are read in name order, and the name is the identity used by `start`, `stop`, `restart`, and `status`. The `.cfg` suffix is optional on the command line.
- Nothing in a config file carries a timeout, a rate limit, a header rewrite rule, or a per-path route. Those are not knobs that exist yet, not knobs with a default.
