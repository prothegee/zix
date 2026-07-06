#!/usr/bin/env bash
# benchmark-httparena-lite.sh - Lite benchmark launcher with widened profiles.
#
# Wraps scripts/benchmark-lite.sh, patching PROFILES in a disposable copy to:
# - Widen HTTP conn sweep to 4096 (stock stops at 512).
# - Enable omitted ws/gRPC profiles (echo-ws-pipeline, stream-grpc[-tls]).
# - Add json-tls (h1 https /json cell). Certs are already mounted.
# - Add h2c cells (baseline-h2c, json-h2c) at the actual HttpArena sweeps.
# The patched copy runs and is removed on exit; paths resolve correctly.
#
# Args (flags can appear anywhere, positionals are <framework> [profile] [httparena-dir]):
#   <framework>       Required. Framework to benchmark (e.g., zix, zix-grpc).
#   [profile]         Optional. Bench only this profile (e.g., baseline). Any
#                     positional that is not an HttpArena folder is the profile,
#                     so order does not matter. Validated before any build.
#   [httparena-dir]   Optional. HttpArena folder (default: script's directory).
#   --load-threads N  Optional. Load-gen threads. When omitted, nothing is
#                     injected: benchmark-lite.sh applies its own default
#                     (nproc/2, env THREADS also honored).
#   --source MODE     Optional. "remote" (default, fetches branch) or "local".
#   --zix-dir DIR     Optional. Local zix checkout for --source local (default: script's dir).
#
# Rootless by default: neutralizes benchmark-lite.sh's root-only system_tune.
# Set TUNE=true to keep tuning and run under sudo.
#
# --source local keeps artifacts temporary (removed on exit): rsyncs zix into
# gitignored vendor/zix, swaps Dockerfile fetch for COPY, and drops a build.sh
# for the HttpArena build hook.
#
# Usage:
#   ./benchmark-httparena-lite.sh zix                              # this folder, all profiles
#   ./benchmark-httparena-lite.sh zix baseline                     # only the baseline profile
#   ./benchmark-httparena-lite.sh zix-grpc                         # gRPC suite
#   ./benchmark-httparena-lite.sh zix --load-threads 6             # override threads
#   ./benchmark-httparena-lite.sh zix-ws /path/HttpArena           # ws, other folder
#   ./benchmark-httparena-lite.sh zix baseline /path/HttpArena     # one profile, other folder
#   ./benchmark-httparena-lite.sh zix /path/HttpArena --source local --zix-dir /path/zix

set -euo pipefail

# Parse arguments: flags anywhere, positionals are <framework> [profile] [httparena-dir].
# LOAD_THREADS empty = not given: benchmark-lite.sh applies its own default (nproc/2).
LOAD_THREADS=
SOURCE=remote
ZIX_DIR=
POSITIONAL=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --load-threads)
            [ "$#" -ge 2 ] || { echo "error: --load-threads needs a value" >&2; exit 1; }
            LOAD_THREADS="$2"; shift 2 ;;
        --load-threads=*) LOAD_THREADS="${1#*=}"; shift ;;
        --source)
            [ "$#" -ge 2 ] || { echo "error: --source needs a value (local|remote)" >&2; exit 1; }
            SOURCE="$2"; shift 2 ;;
        --source=*) SOURCE="${1#*=}"; shift ;;
        --zix-dir)
            [ "$#" -ge 2 ] || { echo "error: --zix-dir needs a value" >&2; exit 1; }
            ZIX_DIR="$2"; shift 2 ;;
        --zix-dir=*) ZIX_DIR="${1#*=}"; shift ;;
        *)                POSITIONAL+=("$1"); shift ;;
    esac
done
case "$SOURCE" in
    local|remote) ;;
    *) echo "error: --source must be 'local' or 'remote', got '$SOURCE'" >&2; exit 1 ;;
esac
if [ "${#POSITIONAL[@]}" -gt 0 ]; then
    set -- "${POSITIONAL[@]}"
else
    set --
fi

# <framework> is required.
FRAMEWORK="${1:-}"
if [ -z "$FRAMEWORK" ]; then
    echo "usage: $(basename "$0") <framework> [profile] [httparena-dir] [--load-threads N]" >&2
    echo "       <framework> is required (e.g. zix, zix-grpc, zix-ws)" >&2
    exit 1
fi
shift

# Classify the remaining positionals: an HttpArena folder (has scripts/benchmark-lite.sh)
# is [httparena-dir], anything else is [profile]. Order does not matter.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR=
PROFILE=
for extra in "$@"; do
    if [ -f "$extra/scripts/benchmark-lite.sh" ]; then
        if [ -n "$REPO_DIR" ]; then
            echo "error: httparena-dir given twice ('$REPO_DIR', '$extra')" >&2
            exit 1
        fi
        REPO_DIR="$extra"
    else
        if [ -n "$PROFILE" ]; then
            echo "error: profile given twice ('$PROFILE', '$extra')" >&2
            exit 1
        fi
        PROFILE="$extra"
    fi
done
REPO_DIR="${REPO_DIR:-$SELF_DIR}"

# Validate [profile] against the patched profile set before any build starts.
KNOWN_PROFILES="baseline pipelined limited-conn json json-comp json-tls upload static async-db baseline-h2 static-h2 baseline-h2c json-h2c baseline-h3 static-h3 unary-grpc unary-grpc-tls stream-grpc stream-grpc-tls echo-ws echo-ws-pipeline"
if [ -n "$PROFILE" ]; then
    case " $KNOWN_PROFILES " in
        *" $PROFILE "*) ;;
        *)
            echo "error: unknown profile '$PROFILE'" >&2
            echo "known profiles: $KNOWN_PROFILES" >&2
            exit 1 ;;
    esac
fi

# --zix-dir defaults to this script's directory.
ZIX_DIR="${ZIX_DIR:-$SELF_DIR}"

SRC="$REPO_DIR/scripts/benchmark-lite.sh"
if [ ! -f "$SRC" ]; then
    echo "error: '$REPO_DIR' is not an HttpArena folder (no scripts/benchmark-lite.sh)" >&2
    exit 1
fi
REPO_DIR="$(cd "$REPO_DIR" && pwd)"

PATCHED="$REPO_DIR/scripts/.benchmark-lite-4096.$$.sh"
FW_SRC="$REPO_DIR/scripts/lib/framework.sh"
FW_PATCHED="$REPO_DIR/scripts/lib/.framework-grpcfix.$$.sh"
ORIG_DIR="$PWD"

# Local-source staging targets (all removed on exit).
FW_DIR="$REPO_DIR/frameworks/$FRAMEWORK"
VENDOR_DIR="$FW_DIR/vendor/zix"
LOCAL_DOCKERFILE="$FW_DIR/.Dockerfile.local.$$"
LOCAL_BUILDSH="$FW_DIR/build.sh"

# Validate --source local before trap to avoid deleting pre-existing tracked build.sh.
if [ "$SOURCE" = "local" ]; then
    if [ ! -f "$ZIX_DIR/build.zig" ] || [ ! -f "$ZIX_DIR/build.zig.zon" ] || [ ! -f "$ZIX_DIR/src/lib.zig" ]; then
        echo "error: --zix-dir '$ZIX_DIR' is not a zix checkout (no build.zig, build.zig.zon or src/lib.zig)" >&2
        exit 1
    fi
    if [ ! -f "$FW_DIR/Dockerfile" ] || ! grep -q 'vendor/zix' "$FW_DIR/Dockerfile"; then
        echo "error: framework '$FRAMEWORK' does not vendor zix; --source local does not apply" >&2
        exit 1
    fi
    if [ -e "$LOCAL_BUILDSH" ]; then
        echo "error: '$LOCAL_BUILDSH' already exists; refusing to overwrite a tracked build.sh" >&2
        exit 1
    fi

    ZIX_DIR="$(cd "$ZIX_DIR" && pwd)"
fi

cleanup() {
    rm -f "$PATCHED" "$FW_PATCHED"

    if [ "$SOURCE" = "local" ]; then
        rm -f "$LOCAL_DOCKERFILE" "$LOCAL_BUILDSH"
        rm -rf "$VENDOR_DIR"
    fi

    cd "$ORIG_DIR" 2>/dev/null || true
}
trap cleanup EXIT

cd "$REPO_DIR"

# Stage local zix source. rsync mirrors checkout to vendor/zix (excluding caches).
# Rewrites Dockerfile vendor-fetch RUN to COPY, and creates build.sh for the harness.
if [ "$SOURCE" = "local" ]; then
    echo "staging local zix from $ZIX_DIR into $VENDOR_DIR" >&2

    rm -rf "$VENDOR_DIR"
    mkdir -p "$VENDOR_DIR"
    rsync -a --delete \
        --exclude '.git' \
        --exclude '.zig-cache' \
        --exclude 'zig-out' \
        --exclude 'rnd' \
        "$ZIX_DIR"/ "$VENDOR_DIR"/

    awk '
        function flush() {
            if (in_run) {
                if (buf ~ /vendor\/zix/) print "COPY vendor/zix /src/vendor/zix";
                else printf "%s", buf;
                buf = ""; in_run = 0;
            }
        }
        {
            if (!in_run && $0 ~ /^RUN /) { in_run = 1; buf = $0 "\n"; if ($0 !~ /\\$/) flush(); next }
            if (in_run) { buf = buf $0 "\n"; if ($0 !~ /\\$/) flush(); next }
            print
        }
        END { flush() }
    ' "$FW_DIR/Dockerfile" > "$LOCAL_DOCKERFILE"

    cat > "$LOCAL_BUILDSH" <<EOF
#!/usr/bin/env bash
# Generated by benchmark-httparena-lite --source local. Removed on exit.
set -euo pipefail

DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"

docker build -t "httparena-$FRAMEWORK" -f "$LOCAL_DOCKERFILE" "\$DIR"
EOF
    chmod +x "$LOCAL_BUILDSH"
fi

# Patch gRPC readiness probe: use docker ghz command if present, return cleanly
# to avoid falling through to unset probe_url under set -u.
sed -E \
    -e 's/(            )_wait_grpc "\$endpoint" \&\& return 0/\1_wait_grpc "$endpoint"\n\1return/' \
    -e 's/if "\$GHZ" "\$flag"/if ${GHZ_CMD:-$GHZ} "$flag"/' \
    "$FW_SRC" > "$FW_PATCHED"

# Patch profiles (format: pipeline|req_per_conn|cpu_limit|connections|endpoint).
# Widens connection sweeps, adds omitted ws/gRPC profiles and json-tls.
# Values mirror full benchmark sweep, trimmed for laptop (e.g., ws caps at 4096).
sed -E \
    -e 's/(\[baseline\]="1\|0\|\|)512(\|")/\1512,4096\2/' \
    -e 's/(\[pipelined\]="16\|0\|\|)512(\|pipeline")/\1512,4096\2/' \
    -e 's/(\[limited-conn\]="1\|10\|\|)512(\|")/\1512,4096\2/' \
    -e 's/(\[json\]="1\|0\|\|)512(\|json")/\14096\2/' \
    -e 's/(\[json-comp\]="1\|0\|\|512\|json-compressed")/\1\n    [json-tls]="1|0||512,4096|json-tls"/' \
    -e 's/(\[upload\]="1\|0\|\|)128(\|upload")/\132,256\2/' \
    -e 's/(\[static\]="1\|10\|\|)512(\|static")/\11024,4096,6800\2/' \
    -e 's/(\[baseline-h2\]="1\|0\|\|)512(\|h2")/\1256,1024\2/' \
    -e 's/(\[static-h2\]="1\|0\|\|)512(\|static-h2")/\1256,1024\2\n    [baseline-h2c]="1|0||256,1024,4096|h2c"\n    [json-h2c]="1|0||1024,4096|json-h2c"/' \
    -e 's/(\[unary-grpc\]="1\|0\|\|)512(\|grpc")/\1256,1024\2/' \
    -e 's/(\[unary-grpc-tls\]="1\|0\|\|)512(\|grpc-tls")/\1256,1024\2/' \
    -e 's/(\[echo-ws\]="1\|0\|\|)512(\|ws-echo")/\1512,4096\2\n    [echo-ws-pipeline]="16|0||512,4096|ws-echo"\n    [stream-grpc]="1|0||64|grpc-stream"\n    [stream-grpc-tls]="1|0||64|grpc-stream-tls"/' \
    -e 's/^([[:space:]]*)echo-ws$/\1echo-ws echo-ws-pipeline\n\1stream-grpc stream-grpc-tls/' \
    -e 's/^([[:space:]]*)json json-comp$/\1json json-comp json-tls/' \
    -e 's/^([[:space:]]*)baseline-h2 static-h2$/\1baseline-h2 static-h2 baseline-h2c json-h2c/' \
    "$SRC" > "$PATCHED"

# Redirect benchmark-lite to source patched framework.sh.
sed -i "s|^source \"\$SOURCE_DIR/framework\.sh\"|source \"$FW_PATCHED\"|" "$PATCHED"

# Rootless by default: neutralize system_tune/restore (requires root) in the copy.
# Loadgens run in containers, so plain users can run it. TUNE=true keeps tuning.
if [ "${TUNE:-false}" != "true" ]; then
    sed -i \
        -e 's/^[[:space:]]*system_tune[[:space:]]*$/true  # system_tune skipped (rootless)/' \
        -e "s/trap 'cleanup_all; system_restore' EXIT/trap 'cleanup_all' EXIT/" \
        "$PATCHED"
fi
chmod +x "$PATCHED"

# Forward only what was given: --load-threads when the user typed it, [profile]
# when set. Otherwise benchmark-lite.sh applies its own defaults.
RUN_ARGS=()
[ -n "$LOAD_THREADS" ] && RUN_ARGS+=(--load-threads "$LOAD_THREADS")
RUN_ARGS+=("$FRAMEWORK")
[ -n "$PROFILE" ] && RUN_ARGS+=("$PROFILE")

if [ "${TUNE:-false}" = "true" ]; then
    sudo -E "$PATCHED" "${RUN_ARGS[@]}"
else
    "$PATCHED" "${RUN_ARGS[@]}"
fi
