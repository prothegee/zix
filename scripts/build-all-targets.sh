#!/usr/bin/env bash
# Important:
# - Do not use this for ci/cd.
# - This meant to be check for developer & maintainer.
# - Test for runner are execute based on native platform.
set -euo pipefail

targets=(
    "x86_64-linux"
    "x86_64-windows"
    "aarch64-macos"
    "aarch64-linux"
    "x86_64-netbsd"
    "x86_64-freebsd"
    "x86_64-openbsd"
)

ZIG_BIN="${1:-zig}"
TARGET_FILTER="${2:-}"

if [[ -n "$TARGET_FILTER" ]]; then
    matched=false
    for target in "${targets[@]}"; do
        if [[ "$target" == "$TARGET_FILTER" ]]; then
            matched=true
            break
        fi
    done

    if [[ "$matched" == false ]]; then
        echo "unknown target: $TARGET_FILTER"
        echo "valid targets: ${targets[*]}"
        exit 1
    fi

    targets=("$TARGET_FILTER")
fi

echo "zig version: $($ZIG_BIN version)"

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

    if ! (cd "$dir" && $ZIG_BIN build "$@" --summary all); then
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
        # echo "$name: $step"
        for target in "${targets[@]}"; do
            # echo "target: $target"
            try_build "$name $step $target" "$dir" $step -Dtarget=$target
        done
    done
}

# --------------------------------------------------------- #

matrix "zix" . install test-all examples test-runner-all

# --------------------------------------------------------- #
# Drivers are standalone packages with their own build.zig. On a foreign
# target the tests and runner compile and skip execution, on the native
# target the container-based steps (test-integration, test-runner) own their
# container lifecycle and need docker running.
# prometheuz has no test-integration step yet (unit + examples + runner).

matrix "postgrez" src/driver/postgrez install test-unit test-integration examples test-runner
matrix "rediz" src/driver/rediz install test-unit test-integration examples test-runner
matrix "prometheuz" src/driver/prometheuz install test-unit examples test-runner

# --------------------------------------------------------- #

if [[ ${#failures[@]} -gt 0 ]]; then
    echo "${#failures[@]} leg(s) failed:"
    for failed_leg in "${failures[@]}"; do
        echo "  FAIL: $failed_leg"
    done
    exit 1
fi

echo "all targets passed"
