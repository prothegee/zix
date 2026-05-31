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

__*Ditambahkan:*__
- Menambahkan TCP raw
- Menambahkan gRPC h2c
- Menambahkan FIX (over TCP)
- Handler/router (Http & gRPC) kini menggunakan comptime
- Dokumentasi dibagi menjadi Bahasa Inggris (en) dan Bahasa Indonesia (id)

__*Diperbaiki:*__
- n/a

<br>

## 0.1.0 (2026-05-16)

__*Ditambahkan:*__
- Rilis awal, jaringan library Zig 0.16.x (minimum_zig_version: 0.16.0-dev.2974+83c7aba12):
    - HTTP:
        - Server dengan tiga dispatch model: POOL, ASYNC, MIXED
        - Router dengan pencocokan exact, param, dan prefix
        - Middleware (comptime, zero-allocation)
        - WebSocket upgrade
        - Server-Sent Events (SSE)
        - Upload multipart
        - Penyajian berkas statis
        - HTTP client
        ---
    - UDP:
        - Server dan client generik atas tipe paket yang didefinisikan pengguna
        - Snapshot peer broadcast per paket
        ---
    - Unix Domain Sockets (UDS):
        - Server dan client dengan framing
        ---
    - Channel:
        - Pengiriman pesan ring buffer in-process, generik atas tipe elemen
        ---
    - Utils:
        - Helper penyimpanan berkas, resolusi tipe MIME
        ---

<br>

__*Diperbaiki:*__
- n/a

<br>

---

###### end of changelog
