#!/usr/bin/env bash
# Important:
# - Do not use this for ci/cd.
# - This meant to be check for developer & maintainer.
# - Test for runner are execute based on native platform.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

parse_target_filter "${1:-zig}" "${2:-}"

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

report_failures
