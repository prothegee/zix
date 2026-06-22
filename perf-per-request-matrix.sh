#!/usr/bin/env bash
set -u
echo "label,route,rep,rps,cyc/req,instr/req,IPC,L1d_loads/req,L1d_miss/req,L1d_miss%,iC_miss/req"
for route in "/" "/echo"; do
  for spec in "epoll:zig-out/bin/example-http1_basic_4_epoll" "uring:zig-out/bin/example-http1_basic_5_uring"; do
    lbl="${spec%%:*}"; bin="${spec#*:}"
    for rep in 1 2 3; do
      bash /tmp/perf_per_req.sh "$bin" 9100 "$route" "$lbl" "$rep"
    done
  done
done
echo "DONE_MATRIX"
