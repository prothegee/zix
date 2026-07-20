#!/bin/sh
# Ephemeral TLS certificate + the postgrez auth matrix.
# Runs once at first container start, after 10-init.sql.
set -e

# self-signed ECDSA P-256, SHA-256 signature (what the driver's
# tls-server-end-point channel binding expects), lives and dies with the
# container
openssl req -new -x509 -days 2 -nodes \
    -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$PGDATA/server.key" -out "$PGDATA/server.crt" \
    -subj "/CN=localhost"
chmod 600 "$PGDATA/server.key"

# ssl only for the final server: the entrypoint's temporary bootstrap server
# starts before this script, so ssl=on must not be a command-line flag
cat >> "$PGDATA/postgresql.conf" <<EOF
ssl = on
EOF

# auth matrix: one role per method, PLUS role must arrive over TLS
cat > "$PGDATA/pg_hba.conf" <<EOF
local   all all                     trust
hostnossl all role_scram_plus 0.0.0.0/0 reject
hostnossl all role_scram_plus ::0/0     reject
hostssl all role_scram_plus 0.0.0.0/0   scram-sha-256
hostssl all role_scram_plus ::0/0       scram-sha-256
host    all role_scram      0.0.0.0/0   scram-sha-256
host    all role_scram      ::0/0       scram-sha-256
host    all role_cleartext  0.0.0.0/0   password
host    all role_cleartext  ::0/0       password
host    all all             0.0.0.0/0   scram-sha-256
host    all all             ::0/0       scram-sha-256
EOF
