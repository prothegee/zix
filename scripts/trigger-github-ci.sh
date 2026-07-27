#!/usr/bin/env bash
# Dispatches the 7 platform CI workflows on GitHub (workflow_dispatch).
#
# Usage:
# - `scripts/trigger-github-ci.sh <branch> <zig-version>` runs every leg on
#   that branch with that zig version's workflow set, i.e.
#   `scripts/trigger-github-ci.sh main 0.16`
# - Both arguments are required: missing args print the help and exit 1
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

usage() {
    {
        echo "Usage: scripts/trigger-github-ci.sh <branch> <zig-version>"
        echo "Example: scripts/trigger-github-ci.sh main 0.16"
        echo "Implemented zig versions: ${implemented_versions[*]}"
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

workflows=(
    x86_64-linux
    aarch64-linux
    aarch64-macos
    x86_64-windows
    x86_64-freebsd
    x86_64-netbsd
    x86_64-openbsd
)

for workflow in "${workflows[@]}"; do
    echo "dispatching zig-${workflow}-${ZIG_VERSION}.yml on ${REF}"
    gh workflow run "zig-${workflow}-${ZIG_VERSION}.yml" --repo "$REPO" --ref "$REF"
done
