#!/usr/bin/env bash
# Important:
# - Sourced by build-all-targets.sh, build-all-targets-no_runner.sh, and
#   trigger-github-ci.sh, not meant to run directly.
# - Holds the shared platform list and array-membership check, plus (for the
#   build-all-targets family) the ZIG_BIN/target-filter parsing, the sweep
#   confirmation, one-leg build, and fan-out matrix runner.
set -euo pipefail

targets=(
    "x86_64-linux"
    "aarch64-macos"
    "aarch64-linux"
    "x86_64-netbsd"
    "x86_64-freebsd"
    "x86_64-windows"
    "x86_64-openbsd"
)

# array_contains VALUE ITEMS...
# Return: 0 if VALUE equals one of ITEMS, 1 otherwise.
array_contains() {
    local value="$1"
    shift

    for item in "$@"; do
        if [[ "$item" == "$value" ]]; then
            return 0
        fi
    done

    return 1
}

ZIG_BIN="zig"

usage_targets() {
    {
        echo "Usage: scripts/$(basename "$0") [zig-bin] [target]"
        echo "Example: scripts/$(basename "$0") zig-0.16"
        echo "Example: scripts/$(basename "$0") zig-0.16 x86_64-linux"
        echo "Known targets: ${targets[*]}"
        echo "Leaving [target] out sweeps every known target and asks first."
    } >&2
}

# confirm_all_targets
# Asks before a sweep, since no target argument means every target in the list
# and that is the long run. Accepts yes/y and no/n in either case. A closed
# stdin counts as no, so an unattended run stops instead of starting the sweep.
confirm_all_targets() {
    local answer=""

    echo "targets: ${targets[*]}"

    while true; do
        if ! read -r -p "You will build all cross-compiled arch and platform, continue? [yes/no] " answer; then
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

# parse_target_filter ZIG_BIN [TARGET]
# Resolves ZIG_BIN and narrows targets to a single entry when TARGET is
# given, prints usage and exits on -h/--help or an unknown target. With no
# TARGET the full list stays and the sweep is confirmed first.
parse_target_filter() {
    local zig_bin="${1:-zig}"
    local target_filter="${2:-}"

    if [[ "$zig_bin" == "-h" || "$zig_bin" == "--help" || "$target_filter" == "-h" || "$target_filter" == "--help" ]]; then
        usage_targets
        exit 0
    fi

    ZIG_BIN="$zig_bin"

    if [[ -n "$target_filter" ]]; then
        if ! array_contains "$target_filter" "${targets[@]}"; then
            echo "error: unknown target: $target_filter" >&2
            usage_targets
            exit 1
        fi

        targets=("$target_filter")
    fi

    echo "zig version: $($ZIG_BIN version)"

    # The version prints first so the answer is given knowing which compiler
    # the sweep would use.
    if [[ -z "$target_filter" ]]; then
        confirm_all_targets
    fi
}

# --------------------------------------------------------- #
# One failing leg must not abort the matrix: every invocation is recorded and
# the script keeps going, then reports every failed leg at the end and exits
# non-zero if there was any.

failures=()

# try_build LABEL DIR BUILD_ARGS...
try_build() {
    local label="$1"
    local dir="$2"
    shift 2

    if ! (cd "$dir" && $ZIG_BIN build "$@" --summary failures); then
        echo "FAIL: $label"
        failures+=("$label")
    fi
}

# matrix NAME DIR STEPS...
# Runs every step for every target ("install" is zig build's default step).
matrix() {
    local name="$1"
    local dir="$2"
    shift 2

    for step in "$@"; do
        for target in "${targets[@]}"; do
            try_build "$name $step $target" "$dir" $step -Dtarget=$target
        done
    done
}

# report_failures
# Prints every failed leg and exits non-zero if any were recorded, otherwise
# prints a pass summary. Call this last.
report_failures() {
    if [[ ${#failures[@]} -gt 0 ]]; then
        echo "${#failures[@]} leg(s) failed:"
        for failed_leg in "${failures[@]}"; do
            echo "  FAIL: $failed_leg"
        done
        exit 1
    fi

    echo "all targets passed"
}
