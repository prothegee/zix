#!/usr/bin/env bash
# Important:
# - Do not use this for ci/cd.
# - This meant to be check for developer & maintainer.
# - Test for runner are execute based on native platform.
# - `install` is skiped, not exists yet.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

parse_target_filter "${1:-zig}" "${2:-}"

# --------------------------------------------------------- #

matrix "zix" . test-all examples zixer test-runner-all

# --------------------------------------------------------- #
# Drivers are standalone packages with their own build.zig. On a foreign
# target the tests and runner compile and skip execution, on the native
# target the container-based steps (test-integration, test-runner) own their
# container lifecycle and need docker running.
# test-behaviour and test-edge drive an in-process server instead, so they need
# no container and run on every target.
# prometheuz has no test-integration step (its container coverage is test-runner).

matrix "postgrez" src/driver/postgrez test-unit test-behaviour test-edge test-integration examples test-runner
matrix "rediz" src/driver/rediz test-unit test-behaviour test-edge test-integration examples test-runner
matrix "prometheuz" src/driver/prometheuz test-unit test-behaviour test-edge examples test-runner

# --------------------------------------------------------- #

report_failures
