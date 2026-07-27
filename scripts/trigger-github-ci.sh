#!/usr/bin/env bash
# Dispatches the 7 platform CI workflows on GitHub (workflow_dispatch).
#
# Usage:
# - `scripts/trigger-github-ci.sh <branch> <zig-version>` runs every leg on
#   that branch with that zig version's workflow set, i.e.
#   `scripts/trigger-github-ci.sh main 0.16`
# - `scripts/trigger-github-ci.sh <branch> <zig-version> <platform>` runs
#   only that one leg, i.e. `scripts/trigger-github-ci.sh main 0.16 x86_64-windows`
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

REPO="prothegee/zix"

# Extend when a new zig version gets its own zig-*-<version>.yml set.
implemented_versions=(
    0.16
)

workflows=(
    x86_64-linux
    x86_64-windows
    aarch64-macos
    aarch64-linux
    x86_64-freebsd
    x86_64-netbsd
    x86_64-openbsd
)

usage() {
    {
        echo "Usage: scripts/trigger-github-ci.sh <branch> <zig-version> [platform]"
        echo "Example: scripts/trigger-github-ci.sh main 0.16"
        echo "Example: scripts/trigger-github-ci.sh main 0.16 x86_64-windows"
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

version_known=false
for version in "${implemented_versions[@]}"; do
    if [ "$version" = "$ZIG_VERSION" ]; then
        version_known=true
        break
    fi
done

if [ "$version_known" = false ]; then
    echo "error: zig ${ZIG_VERSION} CI legs are not implemented yet" >&2
    usage
    exit 1
fi

PLATFORM="${3:-}"

if [ -n "$PLATFORM" ]; then
    platform_known=false
    for workflow in "${workflows[@]}"; do
        if [ "$workflow" = "$PLATFORM" ]; then
            platform_known=true
            break
        fi
    done

    if [ "$platform_known" = false ]; then
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
