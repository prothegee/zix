#!/usr/bin/env bash
# Important:
# - Do not use this for ci/cd.
# - This meant to be check for developer & maintainer.
# - Test runner are skiped.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

parse_target_filter "${1:-zig}" "${2:-}"

# --------------------------------------------------------- #

matrix "zix" . install test-all examples

# --------------------------------------------------------- #
# Drivers are standalone packages with their own build.zig. On a foreign
# target the tests compile and skip execution, on the native
# target the container-based steps (test-integration) own their
# container lifecycle and need docker running.
# prometheuz has no test-integration step yet (unit + examples).

matrix "postgrez" src/driver/postgrez install test-unit test-integration examples
matrix "rediz" src/driver/rediz install test-unit test-integration examples
matrix "prometheuz" src/driver/prometheuz install test-unit examples

# --------------------------------------------------------- #

report_failures
