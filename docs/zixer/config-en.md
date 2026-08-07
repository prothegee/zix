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
| workers | `1` | worker count, `0` means every available thread | reported only, see below | above the machine thread count it faults and stays at the default |
| dispatch | `async` | dispatch model: `async`, `epoll`, `uring` | reported only, see below | `epoll` and `uring` fault off Linux, any other word faults everywhere |
| logs_dir | `<root>/logs` | where log output will be written | the directory must exist, nothing writes into it yet | a missing directory faults and `status` exits 1 |
| sites_dir | `<root>/sites` | where site `.cfg` files are read from | every `list`, `status`, `start`, and `restart` | a missing directory faults, and no site is found |
| kernel_backlog | `1024` | default listen queue length for tcp site listeners | http1, http2, and grpc sites without their own value, plus the acme companion listener | `0` faults, the kernel still caps the value at `net.core.somaxconn` |
| max_recv_buf | `1472` | intended receive buffer size | reported only, see below | below `1` it faults |

Only `logs_dir`, `sites_dir`, and `kernel_backlog` change what the daemon does. A blank `main.cfg` is valid: every key falls back to the defaults above.

### Keys that are validated but not applied yet

`workers`, `dispatch`, and `max_recv_buf` are parsed, range-checked, and printed by `zixer status`, and nothing in the serving path reads them. Setting them does not change how the daemon runs:

- A daemon started with `workers: 1` and one with `workers: 12` hold the same thread count, before and after traffic.
- `dispatch: async`, `dispatch: epoll`, and `dispatch: uring` all serve through the same edge loops. Each site owns one accept thread and dispatches each connection as a concurrent task.
- `max_recv_buf: 1` still serves a 1 MiB static file byte for byte and still forwards a 60,000 byte datagram intact, because every edge sizes its own buffers.

Treat all three as reserved. They are kept because the validation is the part an operator needs first (a config that will be honored later must still be refused now when it is wrong), but do not size a machine around them.

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
| max_recv_buf | main.cfg value | intended receive buffer size | reported only, same as in main.cfg | below `1` faults |
| upstream_timeout_ms | `30000` | how long the edge waits on a silent upstream before answering 504 | http1, http2, http3, refused on grpc and udp | needs `upstreams`, `0` waits forever, above 4294967295 faults |

`ip` and `port` together decide the listening socket. `0.0.0.0` binds every interface, `127.0.0.1` binds loopback only, `::` binds every IPv6 interface.

### Forwarded says proto=http even on a TLS site

Every proxied request carries a `Forwarded` header (rfc 7239) with the client address, the scheme, and the original host:

```
forwarded: for="127.0.0.1:50250";proto=http;host="localhost:9707"
```

The `proto` parameter is `http` on every edge today, including a TLS one. A backend that decides "was this request secure" from that header will read it wrong on a `tls: true` site, so decide that from the port the backend listens on instead.

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
| max_recv_buf | accepted, no effect | accepted, no effect | accepted, no effect | accepted, no effect | accepted, no effect |
| upstream_timeout_ms | yes | yes | refused | yes | refused |

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
| `spa_fallback` with upstreams but no prefix | `needs public_prefix when upstreams are set` |
| `acme_webroot` and `acme_proxy` together | `choose acme_webroot or acme_proxy, not both` |
| acme keys on a cleartext http2, grpc, or http3 site | `needs tls: true or an http1 site` |
| `engine: http3` without tls | `tls: http3 requires tls: true` |
| `public_dir` or `upstream_timeout_ms` on a grpc site | `not supported on grpc sites, remove it` |
| `upstream_timeout_ms` on a site with no upstreams | `needs upstreams` |
| `tls` on a udp site | `udp forward is blind bytes, tls does not apply` |
| `public_dir`, `kernel_backlog`, `upstream_timeout_ms`, or acme keys on a udp site | `does not apply to udp sites, remove it` |

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
max_recv_buf: 1472
kernel_backlog: 1024

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

Static single page app, no backend:

```
engine: http1
ip: 0.0.0.0
port: 8080
public_dir: /var/www/app/dist
spa_fallback: index.html
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
