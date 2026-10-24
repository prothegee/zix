# uuidz high-level design

## Scope

`uuidz` adalah library UUID dengan Zig murni, hanya library standar. Library ini men-generate dan mem-parse tiga versi UUID yang mencakup kasus umum: v1 untuk identifier berbasis waktu lama, v4 untuk identifier acak, dan v7 untuk identifier terurut waktu.

Dokumen ini membahas bentuk library: layer, komponen, tiga alur, dan substrate bersama. Detail tingkat bit ada di `lld-en.md`.

Desain memegang satu ide: setiap versi menyediakan empat call yang sama, sehingga pemanggil yang menukar satu versi ke versi lain hanya mengubah apa yang dibawa identifier dan tidak mengubah cara pakainya.

<br>

## Layer

```mermaid
flowchart TB
    app[Kode konsumen]
    subgraph api [Public API]
        v1[v1.init / v1.initFromString]
        v4[v4.init / v4.initFromString]
        v7[v7.init / v7.initFromString]
    end
    subgraph substrate [Substrate]
        hex[hex charset]
        mutex[mutex]
        clock[akses clock]
        random[secure random]
    end
    buf[Buffer pemanggil]

    app --> api
    v1 --> mutex
    v1 --> clock
    v1 --> random
    v4 --> random
    v7 --> mutex
    v7 --> clock
    v7 --> random
    v1 --> hex
    v4 --> hex
    v7 --> hex
    api --> buf
```

- Layer API adalah tiga struct, satu per versi. Masing-masing memiliki empat call yang sama dan layout bit khusus versinya.
- Substrate memiliki mekanismenya: hex alphabet, mutex yang membuat v1 dan v7 aman saat konkurensi, pembacaan clock, dan pengisian secure random.
- Buffer milik pemanggil. `uuidz` tidak memegang buffer maupun allocator.

<br>

## Komponen

| Komponen | Tanggung jawab |
| :- | :- |
| `lib.zig` | Permukaan publik: mengekspor `v1`, `v4`, `v7`, dan konstanta versi bersama |
| `hex.zig` | Satu hex alphabet: `0123456789abcdef` |
| `v1.zig` | Versi 1: timestamp, clock sequence, node, mutex, dan epoch offset |
| `v4.zig` | Versi 4: pengisian secure random dan masking versi/varian |
| `v7.zig` | Versi 7: timestamp milidetik, penanganan monotonicity, masking versi/varian |

<br>

## Alur generate

```mermaid
sequenceDiagram
    participant C as Pemanggil
    participant V as struct versi
    participant R as Secure random
    participant K as Clock

    C->>V: init(io)
    alt v1
        V->>V: lock mutex
        V->>R: randomSecure(node) (sekali)
        V->>R: randomSecure(clock_seq) (sekali)
        V->>K: now()
        V->>V: susun timestamp, clock sequence, node
        V->>V: unlock mutex
    else v4
        V->>R: randomSecure(data[0..16])
        V->>V: mask versi ke 4
        V->>V: mask varian ke RFC 4122
    else v7
        V->>V: lock mutex
        V->>K: now()
        V->>V: susun timestamp milidetik 48 bit
        V->>R: randomSecure(bagian acak)
        V->>V: tangani kasus milidetik sama dan clock mundur
        V->>V: mask versi ke 7
        V->>V: mask varian ke RFC 4122
        V->>V: unlock mutex
    end
    V-->>C: Self
```

Tidak ada alokasi. UUID hasil generate adalah 16 byte di field `data` pada struct versi.

<br>

## Alur parse

```mermaid
sequenceDiagram
    participant C as Pemanggil
    participant V as struct versi

    C->>V: initFromString(str)
    V->>V: cek panjang 36 atau 32
    V->>V: jelajahi 16 byte, lewati tanda hubung di bentuk 36 karakter
    V->>V: decode dua karakter hex per byte
    V->>V: cek bit versi
    V->>V: cek bit varian
    V-->>C: Self, atau error
```

Tidak ada alokasi. Nilai hasil parse memiliki 16 byte inline.

<br>

## Alur format

```mermaid
sequenceDiagram
    participant C as Pemanggil
    participant V as struct versi
    participant B as Buffer pemanggil

    C->>V: asString(buf) atau asReffID(buf)
    V->>B: tulis karakter hex
    alt asString
        V->>B: sisipkan tanda hubung di 8, 13, 18, 23
    else asReffID
        V->>B: tanpa tanda hubung
    end
    V-->>C: slice yang sudah terisi
```

Tidak ada alokasi. Pemanggil menyediakan buffer: `[36]u8` untuk `asString`, `[32]u8` untuk `asReffID`.

<br>

## Model alokasi

| Arah | Apa yang dialokasikan | Siapa pemiliknya |
| :- | :- | :- |
| Generate | tidak ada | struct yang dikembalikan memegang 16 byte inline |
| Parse | tidak ada | struct yang dikembalikan memegang 16 byte inline |
| Format | tidak ada | buffer tetap milik pemanggil memegang seluruh string |

<br>

## Model error

Dua kumpulan error, satu untuk generate dan satu untuk parse.

- `init` hanya melaporkan error dari layer IO (pengisian random atau pembacaan clock). Ini tidak mengalokasikan dan tidak memvalidasi hasilnya.
- `initFromString` melaporkan kumpulan parse: `InvalidUuidLength`, `InvalidUuidFormat`, `InvalidHexCharacter`, `InvalidUuidVersion`, `InvalidUuidVariant`. Setiap versi memakai kumpulan yang sama.

Menukar versi tidak pernah mengubah apa yang harus ditangani pemanggil di sisi parse. Sisi generate mewarisi kumpulan error IO dari library standar.
