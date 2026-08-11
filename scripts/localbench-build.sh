#!/usr/bin/env bash
# localbench-build.sh - Build localbench entries and prepare what they need to run.
#
# Each localbench entry under localbench/ is a standalone zig package that depends on
# this checkout by path, so building one builds the local zix source. This script builds
# one entry or all of them, and prepares the two things every entry needs before it can
# serve: the fixture directory and a TLS certificate.
#
# Fixtures come from an HttpArena checkout. Nothing is copied into this repository: the
# entries read dataset.json and the static set straight out of <httparena-dir>/data, and
# the load generators read their templates out of <httparena-dir>/requests. Without that
# checkout the script offers the tracked localbench/static.zip instead, which covers the
# static profiles only.
#
# The certificate is generated here (self-signed Ed25519, CN=localhost), never committed.
# It is regenerated only when absent, so a rebuild does not invalidate a running server.
#
# Everything this script creates outside localbench/ is temporary and removed on exit,
# including after Ctrl-C.
#
# Args (flags anywhere, positionals are <entry> [httparena-dir]):
#   <entry>           Required. An entry directory name, or "all" for every entry.
#   [httparena-dir]   Optional. HttpArena checkout (default: sibling HttpArena next to this one).
#   --release         Optional. Build with --release=fast (default: debug, as zix does elsewhere).
#   --out-dir DIR     Optional. Log directory (default: logs/localbench).
#   --list            Optional. Print the entries that have sources and exit.
#
# Usage:
#   ./scripts/localbench-build.sh all
#   ./scripts/localbench-build.sh http1-uring
#   ./scripts/localbench-build.sh http1-uring /path/HttpArena --release --out-dir logs/localbench

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SELF_DIR/.." && pwd)"
BENCH_DIR="$ROOT_DIR/localbench"
CERTS_DIR="$BENCH_DIR/certs"

ZIG_BIN="${ZIG_BIN:-zig-0.16}"

TMP_DIR=""

info() { echo "[build] $*"; }
fail() { echo "[build] error: $*" >&2; exit 1; }

# cleanup
# Runs on every exit path including Ctrl-C. Removes only what this script made, the
# built binaries and the certificate are the deliverable and stay.
cleanup() {
    local status=$?

    [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"

    return "$status"
}
trap cleanup EXIT INT TERM

# entries_with_sources
# Every localbench directory that actually holds a build.zig, in name order. An empty
# scaffold directory is skipped rather than reported as a build failure.
entries_with_sources() {
    local dir
    for dir in "$BENCH_DIR"/*/; do
        [ -f "${dir}build.zig" ] || continue

        basename "${dir%/}"
    done | sort
}

RELEASE=0
DO_LIST=0
OUT_DIR=""
POSITIONAL=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --release) RELEASE=1; shift ;;
        --list) DO_LIST=1; shift ;;
        --out-dir)
            [ "$#" -ge 2 ] || fail "--out-dir needs a value"
            OUT_DIR="$2"; shift 2 ;;
        --out-dir=*) OUT_DIR="${1#*=}"; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        -*) fail "unknown flag '$1'" ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

if [ "$DO_LIST" -eq 1 ]; then
    entries_with_sources
    exit 0
fi

if [ "${#POSITIONAL[@]}" -eq 0 ]; then
    echo "usage: $(basename "$0") <entry|all> [httparena-dir] [--release] [--out-dir DIR]" >&2
    echo "       entries with sources: $(entries_with_sources | tr '\n' ' ')" >&2
    exit 1
fi

ENTRY="${POSITIONAL[0]}"
ARENA_DIR="${POSITIONAL[1]:-$ROOT_DIR/../HttpArena}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/logs/localbench}"

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
TMP_DIR="$(mktemp -d)"
LOG_FILE="$OUT_DIR/build-$ENTRY-$(date +%Y%m%d-%H%M%S).txt"

# ensure_fixtures
# Point the run at an HttpArena checkout, or fall back to the tracked static.zip after
# asking. A closed stdin counts as no, so an unattended run stops instead of silently
# measuring a fraction of the surface.
ensure_fixtures() {
    if [ -d "$ARENA_DIR/data" ] && [ -d "$ARENA_DIR/requests" ]; then
        ARENA_DIR="$(cd "$ARENA_DIR" && pwd)"

        # The entries name localbench/data the way an arena entry names /data,
        # so point it at the checkout instead of copying 38M into the repo.
        rm -rf "$BENCH_DIR/data"
        ln -s "$ARENA_DIR/data" "$BENCH_DIR/data"

        info "fixtures: $BENCH_DIR/data -> $ARENA_DIR/data"
        info "templates: $ARENA_DIR/requests"

        return 0
    fi

    echo "[build] no HttpArena checkout at $ARENA_DIR" >&2
    echo "[build] we'll use zip data dir and it will be extracted, which covers the static" >&2
    echo "[build] profiles only (no dataset.json, no request templates, no database seed)" >&2

    local answer=""
    while true; do
        if ! read -r -p "[build] extract localbench/static.zip and continue? [yes/no] " answer; then
            fail "stdin closed, refusing to continue without fixtures"
        fi

        case "${answer,,}" in
            y|yes) break ;;
            n|no) fail "no fixtures, nothing to build against" ;;
            *) echo "[build] answer yes or no" >&2 ;;
        esac
    done

    [ -f "$BENCH_DIR/static.zip" ] || fail "localbench/static.zip is missing too"
    command -v unzip >/dev/null 2>&1 || fail "unzip is not installed"

    mkdir -p "$BENCH_DIR/data"
    unzip -q -o "$BENCH_DIR/static.zip" -d "$BENCH_DIR/data"
    ARENA_DIR="$BENCH_DIR"
    info "extracted static.zip to $BENCH_DIR/data/static"
}

# ensure_certs
# Self-signed Ed25519 pair, CN=localhost, the same shape the HttpArena zix Dockerfile
# bakes at image build. Regenerated only when absent.
ensure_certs() {
    if [ -s "$CERTS_DIR/server.crt" ] && [ -s "$CERTS_DIR/server.key" ]; then
        info "certificate: $CERTS_DIR/server.crt (kept)"

        return 0
    fi

    command -v openssl >/dev/null 2>&1 || fail "openssl is not installed"

    mkdir -p "$CERTS_DIR"
    openssl genpkey -algorithm ED25519 -out "$CERTS_DIR/server.key" 2>/dev/null
    openssl req -new -x509 -key "$CERTS_DIR/server.key" -out "$CERTS_DIR/server.crt" \
        -days 3650 -subj "/CN=localhost" 2>/dev/null
    chmod 600 "$CERTS_DIR/server.key"
    info "certificate: $CERTS_DIR/server.crt (generated)"
}

# build_gateway_edge ENTRY
# A gateway entry is two processes: the zixer proxy at the edge and the origin
# behind it. zixer keeps its own build files at the repository root and is
# shared by every gateway entry, so it is built once here rather than per entry.
# Its logs directory is not in the repository, and a missing one faults the
# daemon at start, so it is created alongside.
build_gateway_edge() {
    local entry="$1"

    mkdir -p "$BENCH_DIR/$entry/logs"

    local -a args=("$ZIG_BIN" build zixer)
    [ "$RELEASE" -eq 1 ] && args+=(--release=fast)

    info "building the zixer edge for $entry"
    (cd "$ROOT_DIR" && "${args[@]}") 2>&1 | tee -a "$LOG_FILE"
}

# build_entry ENTRY
build_entry() {
    local entry="$1"
    local dir="$BENCH_DIR/$entry"

    [ -f "$dir/build.zig" ] || fail "$entry has no build.zig (still an empty scaffold?)"

    local -a args=("$ZIG_BIN" build)
    [ "$RELEASE" -eq 1 ] && args+=(--release=fast)

    info "building $entry"
    (cd "$dir" && "${args[@]}") 2>&1 | tee -a "$LOG_FILE"

    case "$entry" in
        gateway-*) build_gateway_edge "$entry" ;;
    esac
}

command -v "$ZIG_BIN" >/dev/null 2>&1 || fail "$ZIG_BIN is not on PATH (set ZIG_BIN to override)"

ensure_fixtures
ensure_certs

if [ "$ENTRY" = "all" ]; then
    mapfile -t TARGETS < <(entries_with_sources)
    [ "${#TARGETS[@]}" -gt 0 ] || fail "no entry under localbench/ has a build.zig yet"
else
    TARGETS=("$ENTRY")
fi

for target in "${TARGETS[@]}"; do
    build_entry "$target"
done

info "built ${#TARGETS[@]} entry/entries"
info "log: $LOG_FILE"
