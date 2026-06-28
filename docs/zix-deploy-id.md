# Panduan deployment zix

Cara membangun aplikasi zix menjadi Docker image (dengan git, curl, dan zig fetch) dan cara
mengonfigurasi TLS context untuk masing-masing dari tiga tipe certificate yang didukung. Untuk
referensi field config TLS lengkap lihat `zix-config-id.md`. Untuk desain TLS lihat `hld-tls-id.md`.

## Menambahkan zix ke project

zix dipakai sebagai package Zig. Deklarasikan di `build.zig.zon` dengan `zig fetch`, lalu import
module-nya di `build.zig`.

Fetch tarball rilis (pin sebuah versi):

```sh
zig fetch --save "https://codeberg.org/prothegee/zix/archive/MAJOR.MINOR.x.tar.gz"
```

Atau fetch langsung dari git (bentuk `git+https`, yang butuh `git` di mesin):

```sh
zig fetch --save "git+https://codeberg.org/prothegee/zix#MAJOR.MINOR.x"   # pinned
zig fetch --save "git+https://codeberg.org/prothegee/zix#main"            # upstream
```

Mirror `github.com/prothegee/zix` bisa dipakai menggantikan codeberg. Lalu sambungkan module di
`build.zig`:

```zig
const zix = b.dependency("zix", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zix", zix.module("zix"));
```

## Membangun Docker image

Build multi-stage menjaga runtime image tetap kecil: stage build mengompilasi binary musl statis,
stage runtime hanya membawa binary itu. Ada dua cara membawa zix ke dalam build, keduanya didukung:

- Opsi A, zig fetch: zix adalah dependency package URL, di-resolve oleh package manager Zig.
- Opsi B, vendor: source zix disalin ke `vendor/zix` (lewat curl atau git) dan dirujuk sebagai
  dependency path lokal, jadi `zig build` tidak butuh network untuk dependency-nya.

Keduanya berbagi argument build yang sama, preamble install toolchain yang sama, dan langkah build
yang sama. Jaga argument ini tetap konsisten:

| arg | contoh | arti |
| :- | :- | :- |
| `ZIG_VERSION` | `0.16.0` | versi toolchain Zig yang diunduh |
| `ZIX_VERSION` | `0.5.x` | branch atau tag zix yang dipakai |
| `TARGETARCH` | `amd64` | diset oleh docker builder, memilih arch target |

Preamble bersama (toolchain plus source Anda):

```dockerfile
# syntax=docker/dockerfile:1.7
FROM alpine:3.20 AS build
ARG ZIG_VERSION=0.16.0
ARG ZIX_VERSION=0.5.x
ARG TARGETARCH
RUN apk add --no-cache ca-certificates curl git tar xz

# install toolchain Zig (arch-aware)
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
        amd64) ZIG_ARCH=x86_64 ;; \
        arm64) ZIG_ARCH=aarch64 ;; \
        *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" \
        | tar -xJ -C /opt; \
    mv "/opt/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}" /opt/zig
ENV PATH="/opt/zig:${PATH}"

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
```

### Opsi A: zig fetch (dependency package)

zix adalah dependency URL di `build.zig.zon`. Jalankan `zig fetch --save` sekali secara lokal untuk
mem-pin versi dan content hash, commit hasilnya, dan build me-resolve-nya dari cache package Zig:

```zig
// build.zig.zon
.dependencies = .{
    .zix = .{
        .url = "https://codeberg.org/prothegee/zix/archive/MAJOR.MINOR.x.tar.gz",
        .hash = "...", // ditulis oleh zig fetch --save
    },
},
```

Tidak perlu langkah Dockerfile tambahan: langkah build di bawah menjalankan `zig build`, yang menarik
zix ke cache. Untuk mem-pin di dalam image (saat `build.zig.zon` tidak membawa hash ter-commit),
jalankan fetch di Dockerfile sebelum build:

```dockerfile
RUN zig fetch --save "https://codeberg.org/prothegee/zix/archive/${ZIX_VERSION}.tar.gz"
```

### Opsi B: vendor salinan lokal (curl atau git)

Salin source zix ke `vendor/zix` dan arahkan `build.zig.zon` ke sana sebagai dependency path. Ini
tidak butuh network saat `zig build`, cocok untuk build reproducible atau air-gapped:

```zig
// build.zig.zon
.dependencies = .{
    .zix = .{ .path = "vendor/zix" },
},
```

```dockerfile
# curl tarball source, fall back ke shallow git clone
RUN set -eu; \
    mkdir -p vendor/zix; \
    curl -fsSL "https://codeberg.org/prothegee/zix/archive/${ZIX_VERSION}.tar.gz" -o /tmp/zix.tar.gz \
        && tar -xz --strip-components=1 -C vendor/zix -f /tmp/zix.tar.gz \
    || git clone --depth 1 --branch "${ZIX_VERSION}" "https://codeberg.org/prothegee/zix.git" vendor/zix
```

### Build dan runtime bersama

Keduanya berakhir dengan build arch-aware dan stage runtime yang sama. Feature TLS x86_64 ditaruh di
case amd64 agar build aarch64 tetap di `baseline`:

```dockerfile
# +aes+pclmul: AES-GCM hardware untuk record layer TLS (AES-NI / PCLMULQDQ).
# +adx: jalur Montgomery fused untuk RSA signing (lewati kalau hanya melayani ECDSA / Ed25519).
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
        amd64) ZIG_TARGET=x86_64-linux-musl; ZIG_CPU="x86_64_v3+aes+pclmul+adx" ;; \
        arm64) ZIG_TARGET=aarch64-linux-musl; ZIG_CPU="baseline" ;; \
    esac; \
    zig build -Dtarget="${ZIG_TARGET}" -Dcpu="${ZIG_CPU}" --release=fast

FROM alpine:3.20
COPY --from=build /src/zig-out/bin/myapp /myapp
EXPOSE 8080
ENTRYPOINT ["/myapp"]
```

Catatan:

- Feature `-Dcpu` bersifat x86_64-spesifik dan berpengaruh ke throughput TLS. `+aes+pclmul`
  mengaktifkan AES-NI / PCLMULQDQ, jadi record layer AES-GCM berjalan di hardware bukan jalur
  software yang sekitar 40x lebih lambat. `+adx` mengaktifkan jalur ADCX / ADOX pada RSA Montgomery
  sign. Pada CPU atau arch tanpa itu, hilangkan flag tersebut dan zix memakai fallback portable-nya.
- Untuk server TLS, mount certificate dan key ke runtime container (misalnya
  `-v /path/to/certs:/certs:ro`) dan arahkan config ke sana, bukan membakar secret ke dalam image.

## Mengonfigurasi TLS

Lampirkan `zix.Tls.Context` ke server untuk opt-in ke TLS pada jalur ter-gate. Context memuat cert
dan key sekali saat startup, memvalidasi policy, dan setiap connection memakai ulang. Tipe key
certificate dideteksi dari certificate, jadi tiga tipe di bawah hanya beda pada file cert / key dan
version floor.

```zig
var tls = try zix.Tls.Context.init(allocator, io, .{
    .cert_path = "certs/server.crt",
    .key_path = "certs/server.key",
    .alpn = &.{.HTTP_1_1}, // .H2 untuk server Http2, atau .{ .H2, .HTTP_1_1 }
});
defer tls.deinit();

var server = zix.Http1.Server.init(handler, .{
    .io = io,
    .ip = "0.0.0.0",
    .port = 9060,
    .tls = &tls,
});
```

### Memilih tipe certificate

zix memverifikasi dan menandatangani ketiganya, tetapi biaya signature saat handshake berbeda. Pilih
signature yang lebih murah kecuali ada syarat eksternal yang memaksa lain:

| urutan | tipe cert | biaya sign relatif | versi TLS | kapan dipakai |
| :- | :- | :- | :- | :- |
| 1 | Ed25519 | terendah | 1.3 saja | default untuk deployment baru, handshake termurah di bawah connection storm |
| 2 | ECDSA P-256 | rendah | 1.2 dan 1.3 | saat butuh floor TLS 1.2, atau CA hanya menerbitkan ECDSA |
| 3 | RSA-2048+ | tertinggi | 1.3 saja | hanya untuk melayani certificate RSA yang sudah diterbitkan (cert RSA bersama atau dari CA) |

Alasan urutan ini: Ed25519 menandatangani CertificateVerify paling murah, ECDSA P-256 beberapa kali
lebih, dan RSA-2048 paling mahal bahkan pada jalur Montgomery fused. Di bawah handshake storm (banyak
connection baru sekaligus) signature adalah biaya panas, jadi Ed25519 paling tahan. RSA didukung
penuh dan cukup cepat dengan `+adx`, tetapi secara merit ia pilihan terakhir: pakai saat harus
menyajikan certificate RSA tertentu, bukan sebagai default.

### Ed25519 (disarankan)

Ed25519 menandatangani hanya pada TLS 1.3 (jalur ServerKeyExchange TLS 1.2 ditandatangani ECDSA),
jadi floor context di 1.3.

```zig
var tls = try zix.Tls.Context.init(allocator, io, .{
    .cert_path = "certs/ed25519_cert.pem",
    .key_path = "certs/ed25519_key.pem",
    .alpn = &.{.HTTP_1_1},
    .min_version = .TLS_1_3,
});
defer tls.deinit();
```

### ECDSA P-256

Tipe certificate default. Ia menandatangani di TLS 1.2 dan 1.3, jadi tidak butuh version floor
(default-nya floor 1.2 dan ceiling 1.3, 1.3 diutamakan).

```zig
var tls = try zix.Tls.Context.init(allocator, io, .{
    .cert_path = "certs/ecdsa_p256_cert.pem",
    .key_path = "certs/ecdsa_p256_key.pem",
    .alpn = &.{.HTTP_1_1},
});
defer tls.deinit();
```

### RSA-2048 atau lebih besar

RSA mengautentikasi CertificateVerify dengan `rsa_pss_rsae_sha256`, yang diwajibkan TLS 1.3 untuk
RSA, jadi certificate RSA butuh floor 1.3 (klien 1.2-only ditolak). RSA-2048 adalah minimum. Build
image dengan `+adx` agar signature memakai jalur Montgomery fused.

```zig
var tls = try zix.Tls.Context.init(allocator, io, .{
    .cert_path = "certs/rsa_2048_cert.pem",
    .key_path = "certs/rsa_2048_key.pem",
    .alpn = &.{.HTTP_1_1},
    .min_version = .TLS_1_3,
});
defer tls.deinit();
```

### Opsi umum

Ketiganya menerima sisa `Tls.Context.Config` (lihat `zix-config-id.md` untuk tabel lengkap):
`max_version`, `curves`, `ciphers`, `prefer_server_ciphers`, dan `hsts_max_age_s`. Curve dan cipher
adalah allow-list tervalidasi, jadi value yang tidak didukung adalah error saat startup. Untuk server
Http2 set `alpn = &.{.H2}` (atau `&.{ .H2, .HTTP_1_1 }` untuk juga menawarkan https/1.1).

### Masalah KTLS

Jika `ktls` tidak dapat ditemukan dan tidak bisa menjalankan tls-related. Lakukan:
```sh
sudo modprobe tls;
```

lalu
```sh
lsmod | grep ^tls;
echo tls | sudo tee /etc/modules-load.d/tls.conf;
```

