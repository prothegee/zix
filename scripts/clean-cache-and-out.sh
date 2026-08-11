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

# Each localbench entry is a standalone package with a cache and an output tree
# of its own. Walked rather than listed, so adding an entry needs no edit here.
# build.zig is what marks an entry: the same directory also holds generated
# ones, and data is a symlink into the fixtures checkout, which is never touched.
for entry in "$(pwd)"/localbench/*/; do
    if [ ! -f "${entry}build.zig" ]; then
        continue
    fi

    rm -rf "${entry}.zig-cache"
    rm -rf "${entry}zig-out"
done
