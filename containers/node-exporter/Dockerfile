# node-exporter test image for the prometheuz scrape gate.
#
# Note:
# - Stock upstream image, no customization: node-exporter needs no auth
#   and no TLS for this gate, and exposes host metrics on :9100 by default.
# - Port inside the container: 9100.

FROM docker.io/prom/node-exporter:latest
