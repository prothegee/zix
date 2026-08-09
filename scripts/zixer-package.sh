#!/usr/bin/env bash
# Important:
# - Do not use this for ci/cd.
# - This meant to be release packaging for developer & maintainer.
# - Builds the zixer executable per target and per optimize mode, then writes
#   one zip per pair into dist/.
# - dist/ and every *.zip in it are gitignored, so nothing here is committable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"

# The lowercase spelling is what zixer-build.zig appends to the installed
# binary, so the argument, the binary suffix, and the zip name are one word.
releases=(
    "debug"
    "releasesafe"
    "releasefast"
    "releasesmall"
)

BIN_DIR="$REPO_DIR/zig-out/bin"
DIST_DIR="$REPO_DIR/dist"
DOCS_DIR="$REPO_DIR/docs/zixer"

usage_package() {
    {
        echo "Usage: scripts/$(basename "$0") [zig-bin] [target|all] [release|all]"
        echo "Example: scripts/$(basename "$0") zig-0.16"
        echo "Example: scripts/$(basename "$0") zig-0.16 x86_64-linux releasefast"
        echo "Example: scripts/$(basename "$0") zig-0.16 all all"
        echo "Known targets: ${targets[*]}"
        echo "Known releases: ${releases[*]}"
        echo "Leaving [target] or [release] out asks before sweeping that list."
        echo "Writes: dist/zixer-<arch>-<os>-<release>.zip"
    } >&2
}

# optimize_mode RELEASE
# Return: the -Doptimize value behind a known lowercase release name.
optimize_mode() {
    case "$1" in
        debug)
            echo "Debug"
            ;;
        releasesafe)
            echo "ReleaseSafe"
            ;;
        releasefast)
            echo "ReleaseFast"
            ;;
        releasesmall)
            echo "ReleaseSmall"
            ;;
    esac
}

# confirm_sweep PROMPT
# Asks before a sweep, since a missing argument means the whole list and that
# is the long run. Accepts yes/y and no/n in either case. A closed stdin counts
# as no, so an unattended run stops instead of starting the sweep.
confirm_sweep() {
    local prompt="$1"
    local answer=""

    while true; do
        if ! read -r -p "$prompt [yes/no] " answer; then
            echo >&2
            echo "no answer given, nothing was built" >&2
            exit 1
        fi

        case "$answer" in
            [Yy] | [Yy][Ee][Ss])
                return
                ;;
            [Nn] | [Nn][Oo])
                echo "cancelled, nothing was built"
                exit 0
                ;;
            *)
                echo "answer yes or no (y or n)" >&2
                ;;
        esac
    done
}

# parse_package_args ZIG_BIN [TARGET] [RELEASE]
# Resolves ZIG_BIN and narrows the target and release lists to a single entry
# when one is named. An explicit `all` takes the whole list at its word, a
# missing argument takes the whole list only after the answer is yes.
parse_package_args() {
    local zig_bin="${1:-zig}"
    local target_filter="${2:-}"
    local release_filter="${3:-}"
    local arg=""

    for arg in "$zig_bin" "$target_filter" "$release_filter"; do
        if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
            usage_package
            exit 0
        fi
    done

    ZIG_BIN="$zig_bin"

    # Matched lowercased, so both releasefast and ReleaseFast name one mode.
    release_filter="${release_filter,,}"

    # Both arguments are checked before either list is narrowed, so the usage
    # printed on a bad release still shows every known target.
    if [[ -n "$target_filter" && "$target_filter" != "all" ]] && ! array_contains "$target_filter" "${targets[@]}"; then
        echo "error: unknown target: $target_filter" >&2
        usage_package
        exit 1
    fi

    if [[ -n "$release_filter" && "$release_filter" != "all" ]] && ! array_contains "$release_filter" "${releases[@]}"; then
        echo "error: unknown release: $release_filter" >&2
        usage_package
        exit 1
    fi

    if [[ -n "$target_filter" && "$target_filter" != "all" ]]; then
        targets=("$target_filter")
    fi

    if [[ -n "$release_filter" && "$release_filter" != "all" ]]; then
        releases=("$release_filter")
    fi

    echo "zig version: $($ZIG_BIN version)"

    # The version prints first so each answer is given knowing which compiler
    # the sweep would use.
    if [[ -z "$target_filter" ]]; then
        echo "targets: ${targets[*]}"
        confirm_sweep "You will build all cross-compiled arch and platform, continue?"
    fi

    if [[ -z "$release_filter" ]]; then
        echo "releases: ${releases[*]}"
        confirm_sweep "You will build all optimize modes, continue?"
    fi
}

# --------------------------------------------------------- #
# One failing leg must not abort the sweep: every build, stage, and zip is
# recorded, the run keeps going, and the failed legs are listed at the end.

package_failures=()

# stage_payload BASE STAGE_DIR
# Copies the built binary in under the plain name `zixer`, keeping whatever
# extension the platform gave it, then the license and the zixer docs beside
# it. Windows carries its .pdb when the mode emitted one.
# Return: 0 when the payload is complete, 1 when the binary is missing.
stage_payload() {
    local base="$1"
    local stage_dir="$2"

    if [[ -f "$BIN_DIR/$base.exe" ]]; then
        cp "$BIN_DIR/$base.exe" "$stage_dir/zixer.exe"

        if [[ -f "$BIN_DIR/$base.pdb" ]]; then
            cp "$BIN_DIR/$base.pdb" "$stage_dir/zixer.pdb"
        fi
    elif [[ -f "$BIN_DIR/$base" ]]; then
        cp "$BIN_DIR/$base" "$stage_dir/zixer"
    else
        echo "error: the build left no binary at $BIN_DIR/$base" >&2
        return 1
    fi

    cp "$REPO_DIR/LICENSE" "$stage_dir/LICENSE"

    # The docs keep their own directory so the sibling links between the en and
    # id pages still resolve once the zip is unpacked.
    mkdir -p "$stage_dir/docs"
    cp "$DOCS_DIR"/*.md "$stage_dir/docs/"

    return 0
}

# package_leg TARGET RELEASE
# Builds one target in one mode and writes dist/<base>.zip from a staging dir.
# Records the leg and moves on when any step of it fails.
package_leg() {
    local target="$1"
    local release="$2"
    local base="zixer-$target-$release"
    local stage_dir="$DIST_DIR/.stage-$base"
    local mode

    mode="$(optimize_mode "$release")"

    if ! (cd "$REPO_DIR" && "$ZIG_BIN" build zixer -Dtarget="$target" -Doptimize="$mode" --summary failures); then
        echo "FAIL: build $base"
        package_failures+=("build $base")
        return
    fi

    rm -rf "$stage_dir"
    mkdir -p "$stage_dir"

    if ! stage_payload "$base" "$stage_dir"; then
        echo "FAIL: stage $base"
        package_failures+=("stage $base")
        rm -rf "$stage_dir"
        return
    fi

    # The old zip is removed rather than added to, so a rerun never leaves an
    # entry from an earlier build sitting inside the archive.
    rm -f "$DIST_DIR/$base.zip"

    if ! (cd "$stage_dir" && zip --quiet --recurse-paths -X "$DIST_DIR/$base.zip" .); then
        echo "FAIL: zip $base"
        package_failures+=("zip $base")
        rm -rf "$stage_dir"
        return
    fi

    rm -rf "$stage_dir"

    echo "packaged: dist/$base.zip"
}

# report_package_failures
# Prints every failed leg and exits non-zero if any were recorded, otherwise
# points at the output directory. Call this last.
report_package_failures() {
    if [[ ${#package_failures[@]} -gt 0 ]]; then
        echo "${#package_failures[@]} leg(s) failed:"
        for failed_leg in "${package_failures[@]}"; do
            echo "  FAIL: $failed_leg"
        done
        exit 1
    fi

    echo "every zip is in dist/"
}

# --------------------------------------------------------- #

parse_package_args "${1:-zig}" "${2:-}" "${3:-}"

mkdir -p "$DIST_DIR"

for target in "${targets[@]}"; do
    for release in "${releases[@]}"; do
        package_leg "$target" "$release"
    done
done

report_package_failures
