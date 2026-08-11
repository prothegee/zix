# localbench: gateway-epoll

A two-tier stack, not one server. The zixer proxy gateway sits at the edge and
a zix.Http1 origin sits behind it.

| Tier | What it is | Where |
| :- | :- | :- |
| edge | zixer, `engine: http2`, TLS 1.3 terminated, h2 to the client | 8443 |
| origin | zix.Http1 on `.EPOLL`, cleartext, http1 re-originated to it | 127.0.0.1:18961 |

The edge answers `/static` itself from its own `public_dir` and proxies
everything else. `public_prefix: /static` bounds the file lookup, so a proxied
request never pays a file stat and an origin 404 stays an origin 404.

<br>

## What the dispatch model means here, and what it does not

zixer's `dispatch` key is **reserved**. It is parsed, range-checked, and printed
by `zixer status`, and nothing in the serving path reads it: `dispatch: async`,
`dispatch: epoll`, and `dispatch: uring` all serve through the same edge loops.

So across `gateway-async`, `gateway-epoll`, and `gateway-uring` **the edge is
identical**. What actually differs is the origin behind it, which really does
run that dispatch model. Read a difference between these three numbers as a
difference in the origin, never in the gateway.

<br>

## What is cached, and what is not

| Route | Served by | Per request |
| :- | :- | :- |
| `/static/*` | edge | `public_dir`, 30 s window |
| `/baseline2` | origin | the sum computed from the query and the body |
| `/json/{count}` | origin | every field serialized from typed dataset values |
| `/async-db` | origin | a live query on the worker's postgres lane |

No response cache at either tier, and nothing is pre-serialized at startup.

The 30 s window on the edge is what lets a `.br` or `.gz` sibling be
negotiated at all: with it off the edge re-opens and re-stats the file on every
request and resolves no sibling.

<br>

## Profiles

| Profile | Mix |
| :- | :- |
| `gateway-64` | 20 URIs: 6 static, 4 baseline, 7 json, 3 async-db |

Six of those twenty are answered by the edge and fourteen cross to the origin,
so the number is a property of the whole stack rather than of either tier.

<br>

## Layout

```
gateway-epoll
|
|___/sites
|   |___gateway.cfg                    (the edge site: h2, TLS, upstream, public_dir)
|
|___/src
|   |___/handlers
|   |   |___baseline.zig               (the /baseline2 route)
|   |   |___json.zig                   (the /json route)
|   |   |___asyncdb.zig                (the /async-db route)
|   |
|   |___/shared
|   |   |___crudcache.zig              (row cache the lane substrate carries)
|   |   |___dataset.zig                (typed fixture load, jzon)
|   |   |___dbpg.zig                   (postgres lanes, one per engine worker)
|   |   |___paths.zig                  (fixture and certificate paths)
|   |   |___response.zig               (400, 404, 503 responders)
|   |   |___util.zig                   (shared byte and number helpers)
|   |
|   |___main.zig                       (route table + origin config)
|
|___build.zig
|___build.zig.zon
|___main.cfg                           (the zixer daemon config)
|___meta.json
|___README.md
```

The origin has no `public_dir`: a static request never reaches it. It also has
no crud route, but `dbpg.zig` is the lane substrate shared byte-identical with
the http1 entries, so it carries the crud job kinds and their row cache rather
than being forked.

`logs/` is created by the scripts and is not in the repository. A missing one
faults the daemon at start.

<br>

## Run it

```bash
./scripts/localbench-build.sh gateway-epoll
./scripts/localbench-validate.sh gateway-epoll
./scripts/localbench-run.sh gateway-epoll
```

The build step also builds zixer, which lives at the repository root and is
shared by all three gateway entries. The scripts start the origin, then the
edge, and stop them in the other order so no request is in flight to an origin
that is already gone.
