PID=$(pgrep -f example-http1_basic_5_uring)

wrk -t6 -c128 -d30s http://127.0.0.1:9100/ &

sudo perf record -e L1-dcache-load-misses -c 2000 -p $PID -o /tmp/pe.data -- sleep 15

sudo perf report --stdio -i /tmp/pe.data | head -40
