# localbench: http1-ws-async

zix.Http1 WebSocket on the `.ASYNC` dispatch model: one accept thread handing each connection to a task.

Cleartext on 8080. `GET /ws` upgrades, then the engine drives the echo loop.

<br>

## What is cached

Nothing. Echo is per connection, so there is nothing to share between them and
no state that outlives a frame.

<br>

## Profiles

| Profile | Drives |
| :- | :- |
| `echo-ws` | one message at a time per connection |
| `echo-ws-pipeline` | 16 messages in flight per connection |
| `echo-ws-limited` | a 10 ms think time between messages |

All three are the same server and the same route. What changes is the shape of
the load, so the coalescing path is what separates them: a pipelined burst is
answered as one write.

<br>

## Layout

```
http1-ws-async
|
|___/src
|   |___/handlers
|   |   |___ws.zig                     (the /ws route)
|   |
|   |___main.zig                       (route table + server config)
|
|___build.zig
|___build.zig.zon
|___meta.json
|___README.md
```

<br>

## Run it

```bash
./scripts/localbench-build.sh http1-ws-async
./scripts/localbench-validate.sh http1-ws-async
./scripts/localbench-run.sh http1-ws-async
```
