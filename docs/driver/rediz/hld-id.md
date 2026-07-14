# Desain tingkat tinggi rediz

## Ruang lingkup

rediz adalah library klien Redis murni Zig, hanya memakai standard library. Ia berbicara langsung dengan protocol RESP, tanpa hiredis, tanpa C. Dokumen ini membahas layer, komponen, siklus hidup koneksi, dan model concurrency. Detail wire-level ada di `lld-id.md`.

## Layer

```mermaid
flowchart TB
    app[Kode pemakai]
    subgraph api [API publik]
        conn[Conn]
        pool[Pool]
        pipe[Pipeline]
    end
    subgraph proto [Protocol]
        resp[RESP encode / decode]
        replyerr[reply error]
    end
    tls[TLS 1.3 dan 1.2]
    net[std.Io socket]

    app --> api
    api --> proto
    conn --> tls
    tls --> net
    conn --> net
```

- `Conn` adalah inti: satu koneksi TCP (atau TLS) dengan send buffer dan arena per reply.
- `Pool` dan `Pipeline` adalah fitur di atas `Conn`.
- Layer protocol meng-encode command dan men-decode reply RESP2 dan RESP3, `reply_error` mengklasifikasi reply error.
- TLS membungkus socket ketika config atau URL `rediss://` memintanya.

## Komponen

| Komponen | Tanggung jawab |
| :- | :- |
| `conn.zig` | connect, handshake HELLO, helper command bertipe, `command` raw, jalur deferred write-behind |
| `pool.zig` | pool koneksi thread-safe dengan antrean waiter FIFO yang terbatas |
| `pipeline.zig` | antre beberapa command di belakang satu flush, satu round trip |
| `protocol/resp.zig` | encode dan decode RESP2 dan RESP3, union `Reply` |
| `reply_error.zig` | enum prefix error dan error server yang ditangkap |
| `tls/` | klien TLS (desain bersama dengan stack TLS zix) |
| `url.zig` | parsing `REDIS_URL` menjadi `Config` |

## Siklus hidup koneksi

```mermaid
sequenceDiagram
    participant C as Conn
    participant S as Server
    opt TLS (rediss)
        Note over C,S: handshake TLS dari byte pertama
    end
    alt AUTO atau RESP3
        C->>S: HELLO 3 (dengan AUTH dan nama CLIENT bila diset)
        S-->>C: map info server
        Note over C: fallback ke RESP2 bila HELLO ditolak
    else RESP2
        opt kredensial diset
            C->>S: AUTH
        end
    end
    opt indeks database diset
        C->>S: SELECT db
    end
    Note over C,S: koneksi kini siap dipakai
```

Sebuah port TLS Redis berbicara TLS dari byte pertama, tidak ada upgrade in-band, jadi ia aktif atau mati untuk port tertentu.

## Model concurrency

rediz bersifat shared-nothing pada tingkat koneksi, model yang sama dengan sisi PostgreSQL:

- Sebuah `Conn` dimiliki satu pihak. Satu thread menggerakkan satu koneksi pada satu waktu, tidak ada lock di dalam koneksi.
- Sebuah `Pool` bersifat thread-safe. `acquire` memberikan koneksi idle, meng-connect slot kosong, atau memarkir pemanggil di antrean waiter FIFO yang terbatas. `release` mengembalikan koneksi, langsung ke waiter tertua bila ada yang parkir. `discard` menghancurkan koneksi rusak sehingga slot connect ulang pada acquire berikutnya.

```mermaid
flowchart LR
    t1[thread 1] --> pool[(Pool)]
    t2[thread 2] --> pool
    tn[thread N] --> pool
    pool --> c1[Conn 1]
    pool --> c2[Conn 2]
    pool --> cn[Conn M]
    c1 --> redis[(Redis)]
    c2 --> redis
    cn --> redis
```

## Alur command dan reply

RESP adalah protocol request dan reply yang ketat: reply datang sesuai urutan command. rediz memakai ini untuk dua bentuk.

Command sinkron: kirim, baca reply-nya, decode.

```mermaid
sequenceDiagram
    participant C as Conn
    participant S as Server
    C->>S: command ter-encode (RESP array)
    S-->>C: reply
    Note over C: decode ke nilai bertipe atau Reply raw
```

Deferred write-behind: kirim command, jangan baca, uras reply yang tertunggak sebelum pembacaan berikutnya.

```mermaid
sequenceDiagram
    participant C as Conn
    participant S as Server
    C->>S: setDeferred (SET di-flush, reply tak dibaca)
    Note over C: satu entri di antrean pending
    C->>S: get (panggilan pembaca-reply)
    S-->>C: reply untuk SET deferred (diuras dulu)
    S-->>C: reply untuk GET
```

## Jalur deferred write-behind

Jalur deferred ada untuk pola mirror: pengisian cache atau invalidasi yang harus sampai ke server tetapi reply-nya tidak dibutuhkan pemanggil di jalur latency. Tiap panggilan deferred meng-encode dan flush command, lalu mencatat bahwa satu reply tertunggak. Sebelum panggilan pembaca-reply mana pun, koneksi menguras reply yang tertunggak lebih dulu, karena reply RESP kembali dalam urutan ketat. Hitungan tertunggak dibatasi `max_pending_replies`, jadi server yang macet menguras pada batas alih-alih menumbuhkan memori. Ini menjaga mirror write-behind lepas dari jalur latency request tanpa thread tambahan.

## TLS

Klien TLS memakai desain yang sama dengan seluruh stack zix: TLS 1.3 dengan fallback 1.2. URL `rediss://` atau `tls = .REQUIRE` menjalankan handshake dari byte pertama pada koneksi.

## Keputusan desain

- Helper bertipe di atas jalan pintas raw: command umum punya method bertipe, `command(args)` mengirim command apa pun dan mengembalikan `Reply` raw, jadi tidak ada yang tak terjangkau.
- RESP3 dengan fallback RESP2: HELLO 3 menegosiasi RESP3, penolakan jatuh di tempat, jadi driver berjalan terhadap Redis 7 dan 8 tanpa ketergantungan khusus versi.
- Reply deferred sebagai data, bukan exception: command yang gagal dalam pipeline atau drain kembali sebagai nilai reply error, jadi satu command buruk tak pernah membatalkan sisa batch.
