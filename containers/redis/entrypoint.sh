#!/bin/sh
# rediz test container entrypoint: generate an ephemeral self-signed TLS
# certificate (ECDSA P-256, matches the rediz TLS client offer), then start
# redis-server with cleartext + TLS listeners and the acl test users.
set -e

TLS_DIR=/tmp/rediz-tls
mkdir -p "$TLS_DIR"

if [ ! -f "$TLS_DIR/server.crt" ]; then
    openssl ecparam -genkey -name prime256v1 -out "$TLS_DIR/server.key"
    openssl req -new -x509 -sha256 -key "$TLS_DIR/server.key" \
        -out "$TLS_DIR/server.crt" -days 2 -subj "/CN=localhost"
fi

exec redis-server \
    --port 6379 \
    --tls-port 6390 \
    --tls-cert-file "$TLS_DIR/server.crt" \
    --tls-key-file "$TLS_DIR/server.key" \
    --tls-auth-clients no \
    --aclfile /etc/redis/users.acl \
    --save '' \
    --appendonly no \
    --protected-mode no
