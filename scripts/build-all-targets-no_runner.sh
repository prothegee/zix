#!/usr/bin/env bash
# Important:
# - Do not use this for ci/cd.
# - This meant to be check for developer & maintainer.
# - Test runner are skiped.
# - `install` is skiped, not exists yet.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

parse_target_filter "${1:-zig}" "${2:-}"

# --------------------------------------------------------- #

matrix "zix" . test-all examples

# --------------------------------------------------------- #
# zixer keeps its own build files and its own steps, so its unit tests and
# demo upstreams are separate legs from zix's.

matrix "zixer" . zixer zixer-unit-test zixer-examples

# --------------------------------------------------------- #
# jzon keeps its own build files and its own steps for the tiered suites under
# tests/jzon. Its src/ tests ride the zix test-all leg above with the rest of
# the library, so only the tiered step is a leg of its own.

matrix "jzon" . jzon-test-all

# --------------------------------------------------------- #
# Drivers are standalone packages with their own build.zig. On a foreign
# target the tests compile and skip execution, on the native
# target the container-based steps (test-integration) own their
# container lifecycle and need docker running.
# prometheuz has no test-integration step yet (unit + examples).

matrix "postgrez" src/driver/postgrez test-unit test-integration examples
matrix "rediz" src/driver/rediz test-unit test-integration examples
matrix "prometheuz" src/driver/prometheuz test-unit examples

# --------------------------------------------------------- #

report_failures
