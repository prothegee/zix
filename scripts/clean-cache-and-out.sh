#!/usr/bin/env bash
set -euo pipefail

if [[ "$(pwd)" != */zix ]]; then
    echo "current dir is not '*/zix'"
    echo "current dir: $(pwd)"
    exit 1
fi

rm -rf "$(pwd)/.zig-cache"
rm -rf "$(pwd)/zig-out"
rm -rf "$(pwd)/src/jzon/.zig-cache"
rm -rf "$(pwd)/src/driver/postgrez/.zig-cache"
rm -rf "$(pwd)/src/driver/rediz/.zig-cache"
rm -rf "$(pwd)/src/driver/prometheuz/.zig-cache"
rm -rf "$(pwd)/src/jzon/zig-out"
rm -rf "$(pwd)/src/driver/postgrez/zig-out"
rm -rf "$(pwd)/src/driver/rediz/zig-out"
rm -rf "$(pwd)/src/driver/prometheuz/zig-out"
