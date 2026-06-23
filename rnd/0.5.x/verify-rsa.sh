#!/usr/bin/env bash
#
# RFC 8017 RSA-signing oracle for the zix RSA signer (rsa-plan.md). openssl is the reference.
#
# Usage:  bash rnd/0.5.x/verify-rsa.sh
# Deps:   openssl (present). The zix hooks are optional until each phase lands:
#         ZIX_RSA_SIGN     - signs `<n_hex> <d_hex> <message> <sig_out_path>` (PKCS#1 v1.5 SHA-256), R1
#         ZIX_RSA_SIGN_PSS - same argv, RSA-PSS, R2
#         ZIX_RSA_KEYSIGN  - signs `<key_pem_path> <message> <sig_out_path>` from a parsed key file
#                            and prints the parsed modulus hex to stdout (PKCS#1 v1.5 SHA-256), R3
# Expect: 1. openssl PKCS#1 v1.5 self-check       -> Verified OK
#         2. openssl RSA-PSS self-check           -> Verified OK
#         3. zix PKCS#1 v1.5 == openssl byte-exact (deterministic) AND openssl verifies it
#         4. zix RSA-PSS verified by openssl (randomized salt, not byte-exact)
#         5. zix key parse (PKCS#1 + PKCS#8): modulus == openssl AND signature byte-exact vs openssl
#         (3 / 4 / 5 are SKIPPED with a notice until the matching hook is set, per rsa-plan.md)
#
# v1.5 is deterministic so the zix signature must be byte-identical to openssl's. PSS is randomized
# (RFC 8017 9.1) so it is checked by openssl verify only, plus a round-trip (zix verifies openssl).

set -u

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PRIV="$TMP/priv.pem"
PUB="$TMP/pub.pem"
MSG="$TMP/msg"

printf 'zix rsa signing oracle, rfc 8017' > "$MSG"

# RSA-2048 keypair (the shared cert size).
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$PRIV" 2>/dev/null
openssl rsa -in "$PRIV" -pubout -out "$PUB" 2>/dev/null

echo "=== 1. openssl PKCS#1 v1.5 self-check (the deterministic oracle) ==="
openssl dgst -sha256 -sign "$PRIV" -out "$TMP/ref_v15.sig" "$MSG"
openssl dgst -sha256 -verify "$PUB" -signature "$TMP/ref_v15.sig" "$MSG"

echo "=== 2. openssl RSA-PSS self-check (rsa_pss_rsae_sha256, saltlen=32) ==="
openssl dgst -sha256 -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:32 \
    -sign "$PRIV" -out "$TMP/ref_pss.sig" "$MSG"
openssl dgst -sha256 -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:32 \
    -verify "$PUB" -signature "$TMP/ref_pss.sig" "$MSG"

# Extract n and d as hex for the zix signer (DER key parsing is plan phase R3).
N_HEX=$(openssl rsa -in "$PRIV" -noout -modulus 2>/dev/null | sed 's/^Modulus=//' | tr 'A-F' 'a-f')
D_HEX=$(openssl rsa -in "$PRIV" -text -noout 2>/dev/null \
    | awk '/^privateExponent:/{f=1;next} /^[^ ]/{f=0} f{gsub(/[: ]/,"");printf "%s",$0}' \
    | sed -E 's/^(00)+//')

echo "=== 3. zix PKCS#1 v1.5: byte-exact vs openssl (deterministic) ==="
if [ -n "${ZIX_RSA_SIGN:-}" ] && [ -x "${ZIX_RSA_SIGN%% *}" ]; then
    $ZIX_RSA_SIGN "$N_HEX" "$D_HEX" "$(cat "$MSG")" "$TMP/zix_v15.sig"
    if cmp -s "$TMP/ref_v15.sig" "$TMP/zix_v15.sig"; then
        echo "  byte-exact match with openssl"
    else
        echo "  FAIL: zix v1.5 signature differs from openssl"
    fi
    openssl dgst -sha256 -verify "$PUB" -signature "$TMP/zix_v15.sig" "$MSG"
else
    echo "  SKIP: set ZIX_RSA_SIGN to the zix signer (plan phase R1 not built yet)"
fi

echo "=== 4. zix RSA-PSS: verified by openssl (randomized salt) ==="
if [ -n "${ZIX_RSA_SIGN_PSS:-}" ] && [ -x "${ZIX_RSA_SIGN_PSS%% *}" ]; then
    $ZIX_RSA_SIGN_PSS "$N_HEX" "$D_HEX" "$(cat "$MSG")" "$TMP/zix_pss.sig"
    openssl dgst -sha256 -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:32 \
        -verify "$PUB" -signature "$TMP/zix_pss.sig" "$MSG"
else
    echo "  SKIP: set ZIX_RSA_SIGN_PSS to the zix PSS signer (plan phase R2 not built yet)"
fi

# PKCS#1 (traditional) form of the same key, alongside the PKCS#8 form genpkey already emitted.
PRIV_PKCS1="$TMP/priv_pkcs1.pem"
openssl rsa -in "$PRIV" -traditional -out "$PRIV_PKCS1" 2>/dev/null

echo "=== 5. zix key parse (PKCS#1 + PKCS#8): modulus + byte-exact signature ==="
if [ -n "${ZIX_RSA_KEYSIGN:-}" ] && [ -x "${ZIX_RSA_KEYSIGN%% *}" ]; then
    for form in "PKCS#8:$PRIV" "PKCS#1:$PRIV_PKCS1"; do
        label="${form%%:*}"
        key="${form#*:}"
        mod=$($ZIX_RSA_KEYSIGN "$key" "$(cat "$MSG")" "$TMP/zix_key.sig")
        if [ "$mod" = "$N_HEX" ]; then
            echo "  $label: modulus round-trips openssl"
        else
            echo "  $label: FAIL modulus mismatch"
        fi
        if cmp -s "$TMP/ref_v15.sig" "$TMP/zix_key.sig"; then
            echo "  $label: signature byte-exact (n and d parsed correctly)"
        else
            echo "  $label: FAIL signature differs from openssl"
        fi
    done
else
    echo "  SKIP: set ZIX_RSA_KEYSIGN to the zix key signer (plan phase R3 not built yet)"
fi
