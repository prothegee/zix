# PostgreSQL 18 test image for the postgrez integration gate.
#
# Note:
# - The TLS certificate is EPHEMERAL: generated at first start inside the
#   container (20-auth.sh), never committed to the repo.
# - Auth matrix per role (pg_hba written by 20-auth.sh):
#   role_scram (scram-sha-256), role_scram_plus (hostssl + scram-sha-256,
#   cleartext rejected), role_cleartext (password).
# - Run with PGDATA on tmpfs and fsync off, test-only speed flags.

FROM docker.io/library/postgres:18-alpine

RUN apk add --no-cache openssl

COPY init.sql /docker-entrypoint-initdb.d/10-init.sql
COPY init-auth.sh /docker-entrypoint-initdb.d/20-auth.sh
