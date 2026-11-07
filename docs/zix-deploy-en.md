# zix deployment guide

How to build a zix application into a Docker image (with git, curl, and zig fetch) and how to
configure the TLS context for each of the three supported certificate types. For the full TLS
config-field reference see `zix-config-en.md`. For the TLS design see `hld-tls-en.md`.

## Add zix to your project

zix is consumed as a Zig package. Declare it in `build.zig.zon` with `zig fetch`, then import the
module in `build.zig`.

Fetch a release tarball (pin a version):

```sh
zig fetch --save "https://codeberg.org/prothegee/zix/archive/MAJOR.MINOR.x.tar.gz"
```

Or fetch straight from git (the `git+https` form, which needs `git` on the machine):

```sh
zig fetch --save "git+https://codeberg.org/prothegee/zix#MAJOR.MINOR.x"   # pinned
zig fetch --save "git+https://codeberg.org/prothegee/zix#main"            # upstream
```

The mirror `github.com/prothegee/zix` works in place of codeberg. Then wire the module in
`build.zig`:

```zig
const zix = b.dependency("zix", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zix", zix.module("zix"));
```

## Build a Docker image

A multi-stage build keeps the runtime image small: a build stage compiles a static musl binary, a
runtime stage carries only that binary. There are two ways to bring zix into the build, both
supported:

- Option A, zig fetch: zix is a URL package dependency, resolved by the Zig package manager.
- Option B, vendor: the zix source is copied into `vendor/zix` (via curl or git) and referenced as a
  local path dependency, so `zig build` needs no network for the dependency.

Both share the same build arguments, the same toolchain-install preamble, and the same build step.
Keep these arguments consistent:

| arg | example | meaning |
| :- | :- | :- |
| `ZIG_VERSION` | `0.16.0` | Zig toolchain version to download |
| `ZIX_VERSION` | `0.5.x` | zix branch or tag to depend on |
| `TARGETARCH` | `amd64` | set by the docker builder, selects the target arch |

Shared preamble (toolchain plus your sources):

```dockerfile
# syntax=docker/dockerfile:1.7
FROM alpine:3.20 AS build
ARG ZIG_VERSION=0.16.0
ARG ZIX_VERSION=0.5.x
ARG TARGETARCH
RUN apk add --no-cache ca-certificates curl git tar xz

# install the Zig toolchain (arch-aware)
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

### Option A: zig fetch (package dependency)

zix is a URL dependency in `build.zig.zon`. Run `zig fetch --save` once locally to pin the version
and content hash, commit the result, and the build resolves it from the Zig package cache:

```zig
// build.zig.zon
.dependencies = .{
    .zix = .{
        .url = "https://codeberg.org/prothegee/zix/archive/MAJOR.MINOR.x.tar.gz",
        .hash = "...", // written by zig fetch --save
    },
},
```

No extra Dockerfile step is needed: the build step below runs `zig build`, which fetches zix into the
cache. To pin inside the image instead (when `build.zig.zon` carries no committed hash), run the
fetch in the Dockerfile before the build:

```dockerfile
RUN zig fetch --save "https://codeberg.org/prothegee/zix/archive/${ZIX_VERSION}.tar.gz"
```

### Option B: vendor a local copy (curl or git)

Copy the zix source into `vendor/zix` and point `build.zig.zon` at it as a path dependency. This
needs no network during `zig build`, which suits reproducible or air-gapped builds:

```zig
// build.zig.zon
.dependencies = .{
    .zix = .{ .path = "vendor/zix" },
},
```

```dockerfile
# curl the source tarball, fall back to a shallow git clone
RUN set -eu; \
    mkdir -p vendor/zix; \
    curl -fsSL "https://codeberg.org/prothegee/zix/archive/${ZIX_VERSION}.tar.gz" -o /tmp/zix.tar.gz \
        && tar -xz --strip-components=1 -C vendor/zix -f /tmp/zix.tar.gz \
    || git clone --depth 1 --branch "${ZIX_VERSION}" "https://codeberg.org/prothegee/zix.git" vendor/zix
```

### Shared build and runtime

Both options finish with the same arch-aware build and runtime stage. The x86_64 TLS features go in
the amd64 case so an aarch64 build stays on `baseline`:

```dockerfile
# +aes+pclmul: hardware AES-GCM for the TLS record layer (AES-NI / PCLMULQDQ).
# +adx: the fused Montgomery path for RSA signing (drop it if you serve only ECDSA / Ed25519).
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

Notes:

- The `-Dcpu` features are x86_64-specific and matter for TLS throughput. `+aes+pclmul` turns on
  AES-NI / PCLMULQDQ, so the AES-GCM record layer runs in hardware instead of the roughly 40x slower
  software path. `+adx` turns on the ADCX / ADOX path of the RSA Montgomery sign. On a CPU or arch
  without them, omit the flags and zix uses its portable fallbacks.
- For a TLS server, mount the certificate and key into the runtime container (for example
  `-v /path/to/certs:/certs:ro`) and point the config at them, rather than baking secrets into the
  image.
- The HTTP/3 server with `dispatch_model = .URING` drives a real io_uring receive loop. io_uring
  needs a high enough `RLIMIT_MEMLOCK` (the `ulimit -l` cap) to register the ring: a container or host
  with the cap too low, an old kernel, or a seccomp sandbox makes the ring unavailable, and each worker
  then falls back to the `.EPOLL` readiness loop on its own (no config change, no startup failure). To
  keep the io_uring path, raise the cap, for example `--ulimit memlock=-1` on the container.

## Configure TLS

Attach a `zix.Tls.Context` to a server to opt into TLS on a gated path. The context loads the cert
and key once at startup, validates the policy, and every connection reuses it. The certificate key
type is detected from the certificate, so the three types below differ only by the cert / key files
and the version floor.

```zig
var tls = try zix.Tls.Context.init(allocator, io, .{
    .cert_path = "certs/server.crt",
    .key_path = "certs/server.key",
    .alpn = &.{.HTTP_1_1}, // .H2 for the Http2 server, or .{ .H2, .HTTP_1_1 }
});
defer tls.deinit();

var server = zix.Http1.Server.init(handler, .{
    .io = io,
    .ip = "0.0.0.0",
    .port = 9060,
    .tls = &tls,
});
```

### Choosing a certificate type

zix verifies and signs all three, but the signature cost at handshake time differs. Prefer the
cheaper signature unless an external requirement forces otherwise:

| order | cert type | relative sign cost | TLS versions | when to use |
| :- | :- | :- | :- | :- |
| 1 | Ed25519 | lowest | 1.3 only | default for new deployments, cheapest handshake under a connection storm |
| 2 | ECDSA P-256 | low | 1.2 and 1.3 | when you need a TLS 1.2 floor, or a CA only issues ECDSA |
| 3 | RSA-2048+ | highest | 1.3 only | only to serve a pre-issued RSA certificate (a shared or CA-issued RSA cert) |

Why this order: Ed25519 signs the CertificateVerify the cheapest, ECDSA P-256 is a few times more,
and RSA-2048 is the most expensive even on the fused Montgomery path. Under a handshake storm (many
fresh connections at once) the signature is the hot cost, so Ed25519 holds up best. RSA is fully
supported and fast enough with `+adx`, but it is the last choice on merit: pick it when you must
present a specific RSA certificate, not by default.

### Ed25519 (recommended)

Ed25519 signs only on TLS 1.3 (the TLS 1.2 ServerKeyExchange path is ECDSA-signed), so floor the
context at 1.3.

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

The default certificate type. It signs on both TLS 1.2 and 1.3, so it needs no version floor (the
defaults are a 1.2 floor and 1.3 ceiling, 1.3 preferred).

```zig
var tls = try zix.Tls.Context.init(allocator, io, .{
    .cert_path = "certs/ecdsa_p256_cert.pem",
    .key_path = "certs/ecdsa_p256_key.pem",
    .alpn = &.{.HTTP_1_1},
});
defer tls.deinit();
```

### RSA-2048 or larger

RSA authenticates the CertificateVerify with `rsa_pss_rsae_sha256`, which TLS 1.3 mandates for RSA,
so an RSA certificate requires a 1.3 floor (a 1.2-only client is rejected). RSA-2048 is the minimum.
Build the image with `+adx` so the signature takes the fused Montgomery path.

```zig
var tls = try zix.Tls.Context.init(allocator, io, .{
    .cert_path = "certs/rsa_2048_cert.pem",
    .key_path = "certs/rsa_2048_key.pem",
    .alpn = &.{.HTTP_1_1},
    .min_version = .TLS_1_3,
});
defer tls.deinit();
```

### Common options

All three accept the rest of `Tls.Context.Config` (see `zix-config-en.md` for the full table):
`max_version`, `curves`, `ciphers`, `prefer_server_ciphers`, and `hsts_max_age_s`. Curves and
ciphers are validated allow-lists, so an unsupported value is a startup error. For the Http2 server
set `alpn = &.{.H2}` (or `&.{ .H2, .HTTP_1_1 }` to also offer https/1.1).

### KTLS Problem

If `ktls` not found and you can't run some tls related. Do:
```sh
sudo modprobe tls;
```

then
```sh
lsmod | grep ^tls;
echo tls | sudo tee /etc/modules-load.d/tls.conf;
```
