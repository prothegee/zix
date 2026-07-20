# Redis 8 test image for the rediz integration gate.
#
# Note:
# - The TLS certificate is EPHEMERAL: generated at container start
#   (entrypoint.sh), never committed to the repo.
# - Auth matrix per user (users.acl): default (nopass, the no-auth path),
#   role_acl (password, exercises HELLO AUTH and two-arg AUTH).
# - Ports inside the container: 6379 cleartext, 6390 TLS.
# - Test-only flags: no persistence (save "", appendonly no).

FROM docker.io/library/redis:8-alpine

RUN apk add --no-cache openssl

COPY users.acl /etc/redis/users.acl
COPY entrypoint.sh /usr/local/bin/rediz-entrypoint.sh
RUN chmod +x /usr/local/bin/rediz-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/rediz-entrypoint.sh"]
