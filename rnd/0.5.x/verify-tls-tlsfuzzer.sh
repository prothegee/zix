#!/usr/bin/env bash
#
# tlsfuzzer adversarial / negative suite against the zix TLS server (port 9060).
#
# Usage:  bash rnd/0.5.x/verify-tls-tlsfuzzer.sh [TLSFUZZER_DIR]   (default ../tlsfuzzer)
# Deps:   tlslite-ng + ecdsa, in a venv (pip is present):
#           python -m venv .venv && .venv/bin/pip install tlslite-ng ecdsa
#         then run with:  PY=.venv/bin/python bash rnd/0.5.x/verify-tls-tlsfuzzer.sh ../tlsfuzzer
# Expect: all curated scripts PASS. The list is zix's surface only (TLS 1.3, ECDSA P-256, ALPN),
#         HRR / KeyUpdate / resumption / RSA scripts are excluded (unimplemented, not defects).

set -u

TLSFUZZER="${1:-../tlsfuzzer}"
PORT=9060
BIN=./zig-out/bin/example-tls_http1_basic
PY="${PY:-python}"

[ -d "$TLSFUZZER/scripts" ] || { echo "tlsfuzzer not at '$TLSFUZZER' (pass the dir as arg 1)"; exit 1; }
"$PY" -c "import tlslite, ecdsa" 2>/dev/null || { echo "missing deps in '$PY': tlslite-ng + ecdsa (see header)"; exit 2; }
[ -x "$BIN" ] || { echo "missing $BIN, run: zig build example-tls_http1_basic"; exit 1; }

SCRIPTS=(
    test-tls13-conversation.py
    test-tls13-finished.py
    test-tls13-finished-plaintext.py
    test-tls13-empty-alert.py
    test-tls13-legacy-version.py
    test-tls13-version-negotiation.py
    test-tls13-ecdsa-in-certificate-verify.py
    test-tls13-signature-algorithms.py
    test-tls13-record-layer-limits.py
    test-tls13-ccs.py
    test-alpn-negotiation.py
)

"$BIN" >/tmp/zix_tlsfuzzer_srv.log 2>&1 &
SRV=$!
for _ in $(seq 1 40); do (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && { exec 3>&-; break; }; sleep 0.1; done

pass=0
fail=0
skip=0
for s in "${SCRIPTS[@]}"; do
    if [ ! -f "$TLSFUZZER/scripts/$s" ]; then
        echo "SKIP $s"
        skip=$((skip + 1))
        continue
    fi

    if PYTHONPATH="$TLSFUZZER" "$PY" "$TLSFUZZER/scripts/$s" -h localhost -p $PORT >"/tmp/zix_tf_${s}.log" 2>&1; then
        echo "PASS $s"
        pass=$((pass + 1))
    else
        echo "FAIL $s  (see /tmp/zix_tf_${s}.log)"
        fail=$((fail + 1))
    fi
done

kill "$SRV" 2>/dev/null
wait "$SRV" 2>/dev/null
echo
echo "=== tlsfuzzer: $pass passed, $fail failed, $skip skipped ==="
[ "$fail" -eq 0 ]
