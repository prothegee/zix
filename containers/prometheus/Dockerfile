# Prometheus test image for the prometheuz remote_write/query gates.
#
# Note:
# - --web.enable-remote-write-receiver is a startup flag (set below, not
#   something prometheus.yml can express).
# - prometheus.yml scrapes node-exporter at localhost:19100: correct when
#   run with --network host (registry_live_demo.zig), a harmless failed
#   scrape target otherwise (the one-shot examples never depend on that
#   scrape succeeding).
# - Port inside the container: 9090.

FROM docker.io/prom/prometheus:latest

COPY prometheus.yml /etc/prometheus/prometheus.yml

CMD ["--config.file=/etc/prometheus/prometheus.yml", "--web.enable-remote-write-receiver"]
