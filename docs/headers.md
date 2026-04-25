# Response Headers — Configuration & Security

## Overview

Every HTTP response in zix can carry custom headers added via `res.addHeader(name, value)`. The number of headers a single response is allowed to carry is controlled by `HttpServerConfig.max_response_headers`, which accepts a `zix.HeaderSize` value.

The backing buffer is arena-allocated per request to exactly the configured cap — no wasted memory, no false ceiling. `addHeader()` returns `error.TooManyHeaders` once the cap is reached.

---

## HeaderSize Tiers

| Variant | Cap | When to use |
| :- | :- | :- |
| `.MINIMAL` | 16 | Simple APIs in a controlled or constrained environment; internal services with no proxy |
| `.COMMON` | 32 | **Default.** Most web applications behind a single proxy or load balancer |
| `.LARGE` | 64 | CDN + proxy stacks; services that emit many CORS, cache, or forwarding headers |
| `.EXTRA_LARGE` | 128 | k8s deployments, service mesh (Envoy/Linkerd), heavy header chains |
| `.{ .CUSTOM = N }` | N | Explicit non-standard cap |

Set it once in `HttpServerConfig`:

```zig
var server = try zix.HttpServer.init(.{
    // ...
    .max_response_headers = .LARGE,              // 64 headers
    // .max_response_headers = .{ .CUSTOM = 48 }, // explicit cap
});
```

---

## Choosing a Tier

**Start with `.COMMON` (32).** Count the headers your heaviest handler actually adds in production, then round up to the next tier. Do not over-provision — a larger cap means a larger per-response stack footprint and a harder limit to reason about under attack.

Typical header counts by deployment:

- Bare service: 2–6 (`Content-Type`, `Content-Length`, `Connection`, `X-Request-ID`, etc.)
- With CORS: +4–6 (`Access-Control-*`, `Vary`, `Access-Control-Max-Age`)
- With caching: +3–4 (`Cache-Control`, `ETag`, `Last-Modified`, `Expires`)
- Behind k8s ingress: +5–10 (forwarding, tracing, X-Forwarded-*, X-Envoy-*)

If you reach 32 headers in normal operation, move to `.LARGE`. If you reach 64, move to `.EXTRA_LARGE`. Do not reach for `.CUSTOM` unless you have a counted reason.

---

## Security Considerations

### Header injection

`addHeader()` rejects any `name` or `value` that contains `\r` (CR) or `\n` (LF):

```
error.InvalidHeaderName   — CR or LF found in header name
error.InvalidHeaderValue  — CR or LF found in header value
```

**Never pass user-controlled data directly into `addHeader()` without sanitization.** Even with the CR/LF guard, header values that include `:` or resemble other headers can confuse upstream proxies. If a value comes from a request body, query param, or path segment, validate it before use.

### Header flooding (cap as a DoS limit)

The cap is not just a usability limit — it is a **defence-in-depth measure**. A misconfigured or compromised handler that loops on `addHeader()` is bounded by `max_response_headers` rather than by memory. With `.common` (32), the worst-case per-response overhead is:

```
32 headers × (name_ptr + value_ptr) = 32 × 32 bytes = 1 KB (stack)
```

With `.extra_large` (128), that rises to ~4 KB. Both are bounded and stack-allocated. Do not set `.custom(N)` to a large number speculatively — it widens the footprint without a corresponding benefit.

### Headers visible to clients

Remember that every header you add is visible to the client (and any proxy between you and the client). Avoid leaking:

- Internal hostnames or IPs in `X-Forwarded-*` echoes
- Stack traces or build metadata in debug headers
- Session tokens or internal tokens in any header value

---

## Runtime Modification Issues

Modifying or adding headers during the response phase is strictly controlled to maintain performance and protocol integrity.

1. **Protocol Violation (Timing)**: HTTP/1.1 requires the status line and all headers to be sent before the body. If `res.send()` has already begun transmitting data, it is physically too late to add new headers.
2. **Buffer Capacity**: The `send()` function stages headers in a 4096-byte stack buffer. Extremely large header sets or runtime modifications that push the total header block size beyond 4KB will result in `error.BufferTooSmall`.
3. **Concurrency Safety**: In a multi-threaded environment, modifying headers while `send()` is processing the buffer can lead to race conditions and data corruption.
4. **Injection Protection**: Any runtime modification using external data must continue to respect the CR/LF injection guards to prevent security vulnerabilities.

---

## Error Handling in Handlers

`addHeader()` returns `!void`. Propagate or handle explicitly:

```zig
// Propagate — surfaces as a 500 if the server catches it
try res.addHeader("X-Foo", "bar");

// Handle explicitly — give the client a meaningful error
res.addHeader("X-Foo", "bar") catch |err| switch (err) {
    error.TooManyHeaders    => { res.setStatus(.INTERNAL_SERVER_ERROR); try res.sendJson("{\"error\":\"too many headers\"}"); return; },
    error.InvalidHeaderName => { res.setStatus(.BAD_REQUEST);           try res.sendJson("{\"error\":\"invalid header name\"}"); return; },
    error.InvalidHeaderValue => { res.setStatus(.BAD_REQUEST);          try res.sendJson("{\"error\":\"invalid header value\"}"); return; },
    else                    => return err,
};
```

See `examples/server_xtra_headers.zig` for a working demonstration of the cap, the overflow path, and the injection guard.

---

## Custom Values > 128

`.{ .CUSTOM = N }` where N > 128 is fully supported — the backing buffer is arena-allocated to exactly N slots per request. That said, if you genuinely need more than 128 custom headers per response, reconsider the design — typical HTTP responses carry 5–20 headers; 128 is already an extreme upper bound.

---

###### end of headers.md
