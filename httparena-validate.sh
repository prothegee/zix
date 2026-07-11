#!/usr/bin/env bash
# validate-httparena.sh - Validate one HttpArena framework against the LOCAL zix checkout.
#
# Behaves like HttpArena/scripts/validate.sh (builds httparena-<framework>, runs it, probes the
# subscribed endpoints, reports PASS / FAIL), but for zix entries it stages the local zix source
# first (--source local), the same mechanism benchmark-httparena-lite.sh uses. So a freshly edited
# local zix is what gets built and validated, not a pinned branch.
#
# Args (flags anywhere, positionals are <framework> [httparena-dir]):
#   <framework>       Required. Framework to validate (e.g. zix_uring_http1-ed25519).
#   [httparena-dir]   Optional. HttpArena folder (default: <script-dir>/../HttpArena).
#   --source MODE     Optional. "local" (default, stages this zix checkout) or "remote".
#   --zix-dir DIR     Optional. Local zix checkout for --source local (default: script's dir).
#
# --source local keeps artifacts temporary (removed on exit): rsyncs zix into gitignored
# vendor/zix, swaps the Dockerfile vendor-fetch RUN for COPY, and drops a build.sh for the
# HttpArena build hook (validate.sh runs frameworks/<fw>/build.sh when present).
#
# Usage:
#   ./validate-httparena.sh zix_uring_http1-ed25519
#   ./validate-httparena.sh zix_epoll_http1-ed25519 ../HttpArena
#   ./validate-httparena.sh zix_uring_http2-ed25519 /path/HttpArena --source local --zix-dir /path/zix

set -euo pipefail

# Parse arguments: flags anywhere, positionals are <framework> [httparena-dir].
SOURCE=local
ZIX_DIR=
POSITIONAL=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --source)
            [ "$#" -ge 2 ] || { echo "error: --source needs a value (local|remote)" >&2; exit 1; }
            SOURCE="$2"; shift 2 ;;
        --source=*) SOURCE="${1#*=}"; shift ;;
        --zix-dir)
            [ "$#" -ge 2 ] || { echo "error: --zix-dir needs a value" >&2; exit 1; }
            ZIX_DIR="$2"; shift 2 ;;
        --zix-dir=*) ZIX_DIR="${1#*=}"; shift ;;
        *) POSITIONAL+=("$1"); shift ;;
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
    echo "usage: $(basename "$0") <framework> [httparena-dir] [--source local|remote] [--zix-dir DIR]" >&2
    echo "       <framework> is required (e.g. zix_uring_http1-ed25519)" >&2
    exit 1
fi

# [httparena-dir] defaults to a sibling HttpArena checkout next to this repo.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${2:-$SELF_DIR/../HttpArena}"

# --zix-dir defaults to this script's directory.
ZIX_DIR="${ZIX_DIR:-$SELF_DIR}"

VALIDATE="$REPO_DIR/scripts/validate.sh"
if [ ! -f "$VALIDATE" ]; then
    echo "error: '$REPO_DIR' is not an HttpArena folder (no scripts/validate.sh)" >&2
    exit 1
fi
REPO_DIR="$(cd "$REPO_DIR" && pwd)"

# Local-source staging targets (all removed on exit).
FW_DIR="$REPO_DIR/frameworks/$FRAMEWORK"
VENDOR_DIR="$FW_DIR/vendor/zix"
LOCAL_DOCKERFILE="$FW_DIR/.Dockerfile.local.$$"
LOCAL_BUILDSH="$FW_DIR/build.sh"

if [ ! -d "$FW_DIR" ]; then
    echo "error: framework '$FRAMEWORK' not found under '$REPO_DIR/frameworks'" >&2
    exit 1
fi

# Validate --source local before the trap, to avoid deleting a pre-existing tracked build.sh.
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
    if [ "$SOURCE" = "local" ]; then
        rm -f "$LOCAL_DOCKERFILE" "$LOCAL_BUILDSH"
        rm -rf "$VENDOR_DIR"
    fi
}
trap cleanup EXIT

# Stage local zix source. rsync mirrors the checkout to vendor/zix (excluding caches), rewrites the
# Dockerfile vendor-fetch RUN into a COPY, and drops a build.sh so validate.sh's build hook uses it.
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
# Generated by validate-httparena --source local. Removed on exit.
set -euo pipefail

DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"

docker build -t "httparena-$FRAMEWORK" -f "$LOCAL_DOCKERFILE" "\$DIR"
EOF
    chmod +x "$LOCAL_BUILDSH"
fi

cd "$REPO_DIR"

bash "$VALIDATE" "$FRAMEWORK"
