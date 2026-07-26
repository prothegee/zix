#!/usr/bin/env bash
# Important:
# - Dispatches the 7 platform CI workflows on GitHub (workflow_dispatch).
# - Requires `gh` authenticated as an account with write access to this
#   repo, so only a machine holding that session can actually trigger a run.
set -euo pipefail

REPO="prothegee/zix"
REF="main"

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
    echo "dispatching ${workflow}.yml"
    gh workflow run "${workflow}.yml" --repo "$REPO" --ref "$REF"
done
