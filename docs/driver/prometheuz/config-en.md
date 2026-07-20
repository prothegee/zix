# prometheuz Config Reference

What every field of `ScrapeConfig`, `WriteConfig`, and `QueryConfig` means, and how changing it affects a running process. Unlike `postgrez`/`rediz` there is no single shared config: a scrape target, a remote_write receiver, and a query API endpoint are three different servers in a real deployment, so each surface carries its own flat struct (see `hld-en.md` for why). Every field has a default, none are required.

## How to read the columns

A cell is left blank when it does not apply.

| column | meaning |
| :- | :- |
| field | the config struct field name |
| default | the value used when the field is omitted |
| controls | what the field does |
| perf impact | where it sits and which metric it moves |
| if lower | consequence of a smaller value |
| if higher | consequence of a larger value |

## ScrapeConfig

Used by `scrapeOnce` and `Scraper`.

| field | default | controls | perf impact | if lower | if higher |
| :- | :- | :- | :- | :- | :- |
| ip | `127.0.0.1` | scrape target host, IP literal or hostname | startup (a hostname adds a lookup) | | a hostname goes through the hosts and DNS lookup |
| port | `9100` | scrape target port | | | |
| path | `/metrics` | scrape target path | | | |
| scrape_interval_ms | `15000` | `Scraper` only: delay between polls | poll cadence vs staleness | fresher data, more scrape load on the target | staler `latest()` results between polls |
| conn_timeout_ms | `5000` | accepted for API-shape parity, not yet enforced (see `hld-en.md`) | | | |
| max_response_body | `4194304` (4 MiB) | caps the scraped response body in bytes | memory bound per scrape | rejects a legitimately large `/metrics` body with `error.BodyTooLarge` | more memory held per in-flight scrape |

`scrape_interval_ms` only matters to `Scraper`: a bare `scrapeOnce` call is one-shot and ignores it.

## WriteConfig

Used by `remoteWrite`.

| field | default | controls | perf impact | if lower | if higher |
| :- | :- | :- | :- | :- | :- |
| ip | `127.0.0.1` | remote_write receiver host | | | |
| port | `9090` | remote_write receiver port | | | |
| path | `/api/v1/write` | remote_write receiver path | | | |
| conn_timeout_ms | `5000` | accepted for API-shape parity, not yet enforced | | | |
| max_response_body | `1048576` (1 MiB) | caps the receiver's response body in bytes | memory bound per push | rejects a large receiver error body with `error.BodyTooLarge` | more memory held per in-flight push |

`max_response_body` here bounds the *receiver's reply*, not the pushed payload: the encoded, snappy-compressed `WriteRequest` the driver sends is sized by however many samples the caller passes to `remoteWrite`, uncapped.

## QueryConfig

Used by `query` and `queryRange`. Carries host and port only: the path is fixed per call (`/api/v1/query`, `/api/v1/query_range`).

| field | default | controls | perf impact | if lower | if higher |
| :- | :- | :- | :- | :- | :- |
| ip | `127.0.0.1` | Prometheus query API host | | | |
| port | `9090` | Prometheus query API port | | | |
| conn_timeout_ms | `5000` | accepted for API-shape parity, not yet enforced | | | |
| max_response_body | `4194304` (4 MiB) | caps the JSON response body in bytes | memory bound per query | rejects a large result set with `error.BodyTooLarge` | more memory held per in-flight query, needed for a `queryRange` call over a wide window or many series |

## Notes

- No field is required: every config field has a usable default, unlike `postgrez.Config.user`.
- No `tls` field on any of the three configs: `http_client.zig` is cleartext only for now (see `hld-en.md`). A target URL beginning `https://` is rejected by `parseScrapeUrl`/`parseWriteUrl`/`parseQueryUrl` with `error.UnsupportedScheme`.
- `conn_timeout_ms` is stored on every config for API-shape parity but not yet enforced by `http_client.zig` - see `hld-en.md`'s "Own HTTP/1.1 client" section for why.
- `max_response_body` defaults differ by surface because the expected body shape differs: a scrape or a query result can be large (many metric families, a wide `queryRange` window), a remote_write receiver's reply is normally a short 2xx or an error message.
