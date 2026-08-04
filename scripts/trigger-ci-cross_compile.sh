#!/usr/bin/env bash
# Dispatches the 7 platform CI workflows on GitHub (workflow_dispatch).
#
# Usage:
# - `scripts/trigger-ci-cross_compile.sh <branch> <zig-version>` runs every leg on
#   that branch with that zig version's workflow set, i.e.
#   `scripts/trigger-ci-cross_compile.sh main 0.16`
# - `scripts/trigger-ci-cross_compile.sh <branch> <zig-version> <platform>` runs
#   only that one leg, i.e. `scripts/trigger-ci-cross_compile.sh main 0.16 x86_64-linux`
# - The first two arguments are required: missing args print the help and
#   exit 1. The platform argument is optional: omit it to run every leg.
# - Results: https://github.com/prothegee/zix/actions or
#   `gh run list --repo prothegee/zix`
#
# Note:
# - The branch must exist on the GitHub mirror and contain the workflow files
#   for the requested zig version, or gh refuses the dispatch.
# - A renamed or new workflow can only be dispatched after it exists on main:
#   GitHub registers workflows from the default branch.
# - Requires `gh` authenticated as an account with write access to this
#   repo, so only a machine holding that session can actually trigger a run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

REPO="prothegee/zix"

# Extend when a new zig version gets its own zig-*-<version>.yml set.
implemented_versions=(
    0.16
)

workflows=("${targets[@]}")

usage() {
    {
        echo "Usage: scripts/trigger-ci-cross_compile.sh <branch> <zig-version> [platform]"
        echo "Example: scripts/trigger-ci-cross_compile.sh main 0.16"
        echo "Example: scripts/trigger-ci-cross_compile.sh main 0.16 x86_64-windows"
        echo "Implemented zig versions: ${implemented_versions[*]}"
        echo "Known platforms: ${workflows[*]}"
    } >&2
}

if [ "$#" -lt 2 ]; then
    echo "error: branch and zig version are required" >&2
    usage
    exit 1
fi

REF="$1"
ZIG_VERSION="$2"

if ! array_contains "$ZIG_VERSION" "${implemented_versions[@]}"; then
    echo "error: zig ${ZIG_VERSION} CI legs are not implemented yet" >&2
    usage
    exit 1
fi

PLATFORM="${3:-}"

if [ -n "$PLATFORM" ]; then
    if ! array_contains "$PLATFORM" "${workflows[@]}"; then
        echo "error: unknown platform ${PLATFORM}" >&2
        usage
        exit 1
    fi

    workflows=("$PLATFORM")
fi

for workflow in "${workflows[@]}"; do
    echo "dispatching zig-${workflow}-${ZIG_VERSION}.yml on ${REF}"
    gh workflow run "zig-${workflow}-${ZIG_VERSION}.yml" --repo "$REPO" --ref "$REF"
done
