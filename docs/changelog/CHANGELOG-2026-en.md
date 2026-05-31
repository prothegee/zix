# CHANGELOG

<!--
IMPORTANT:
- Do not remove this
- Naming file is always based on year
- The latest is always on top, bottom next is previous change
- Format:
```
## MAJOR.MINOR.PATCH (YYYY-MM-DD)

__*Update:*__
- Foo
- Bar:
    - Baz
    ---

<br>

__*Fix:*__

- ISSUE_FIX_SHORT_NAME:
    - ISSUE_LINK
    - SHORT_SUMMARY
    - PROFILE_CONTRIBUTOR:
        - NAME_OR_USERNAME / PROFILE_LINK

<br>

## PREVIOUS_CHANGELOG
...
```
-->

<br>

## 0.2.0 (2026-06-1)

__*Update:*__
- Adding TCP raw
- Adding gRPC h2c
- Adding FIX (over TCP)
- Handler/router (Http & gRPC) now use comptime
- Documentation split into Enlish (en) and Bahasa (id)

__*Fix:*__
- n/a

<br>

## 0.1.0 (2026-05-16)

__*Update:*__
- Initial release, Zig 0.16.x network library (minimum_zig_version: 0.16.0-dev.2974+83c7aba12):
    - HTTP:
        - Server with three dispatch models: POOL, ASYNC, MIXED
        - Router with exact, param, and prefix matching
        - Middleware (comptime, zero-allocation)
        - WebSocket upgrade
        - Server-Sent Events (SSE)
        - Multipart upload
        - Static file serving
        - HTTP client
        ---
    - UDP:
        - Generic server and client over user-defined packet type
        - Broadcast peer snapshot per packet
        ---
    - Unix Domain Sockets (UDS):
        - Framed server and client
        ---
    - Channel:
        - In-process ring-buffer message passing, generic over element type
        ---
    - Utils:
        - File save helper, MIME type resolution
        ---

<br>

__*Fix*:__
- n/a

<br>

---

###### end of changelog
