# verify-rsa: openssl RSA-signing oracle (RFC 8017)

The RFC gate for the zix RSA signer (`rsa-plan.md`). openssl is the reference. The zix signer is
checked two ways: PKCS#1 v1.5 is deterministic, so its output must be byte-identical to openssl, and
RSA-PSS is randomized, so it is checked by openssl verify plus a round-trip.

Runnable harness: `rnd/0.5.x/verify-rsa.sh`. The zix hooks are optional and skip until each phase
lands: `ZIX_RSA_SIGN` (R1, v1.5), `ZIX_RSA_SIGN_PSS` (R2, PSS), `ZIX_RSA_KEYSIGN` (R3, signs from a
parsed key file and prints the modulus).

## Steps

```sh
# 1. RSA-2048 keypair (the shared cert size)
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out priv.pem
openssl rsa -in priv.pem -pubout -out pub.pem
printf 'zix rsa signing oracle, rfc 8017' > msg

# 2. PKCS#1 v1.5 reference (deterministic, RFC 8017 8.2)
openssl dgst -sha256 -sign priv.pem -out ref_v15.sig msg
openssl dgst -sha256 -verify pub.pem -signature ref_v15.sig msg

# 3. RSA-PSS reference (rsa_pss_rsae_sha256, saltlen 32, RFC 8017 8.1)
openssl dgst -sha256 -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:32 \
    -sign priv.pem -out ref_pss.sig msg
openssl dgst -sha256 -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:32 \
    -verify pub.pem -signature ref_pss.sig msg

# 4. (once the zix signer lands) byte-exact v1.5 + openssl-verified PSS
zix_rsa_sign "$n_hex" "$d_hex" "$(cat msg)" zix_v15.sig
cmp ref_v15.sig zix_v15.sig                                  # must match (deterministic)
openssl dgst -sha256 -verify pub.pem -signature zix_v15.sig msg

# 5. (R3) sign straight from a key file: PKCS#8 (priv.pem) and PKCS#1 (traditional)
openssl rsa -in priv.pem -traditional -out priv_pkcs1.pem
mod=$(zix_rsa_keysign priv.pem "$(cat msg)" zix_key.sig)     # stdout is the parsed modulus hex
[ "$mod" = "$n_hex" ] && echo "modulus round-trips"          # must equal openssl -modulus
cmp ref_v15.sig zix_key.sig                                  # byte-exact proves n and d
```

## Expected

| Check | Expected |
| :- | :- |
| openssl v1.5 verify | `Verified OK` |
| openssl PSS verify | `Verified OK` |
| zix v1.5 vs openssl | `cmp` reports no difference (byte-exact) |
| openssl verifies zix v1.5 | `Verified OK` |
| openssl verifies zix PSS | `Verified OK` (salt differs, so not byte-exact) |
| zix verifies openssl PSS | accepted (round-trip; std already does RSA verify) |
| zix key parse modulus (PKCS#1 + PKCS#8) | equals `openssl rsa -modulus` |
| zix sign from parsed key | byte-exact vs openssl (proves n and d parsed) |

## Notes

- v1.5 must be byte-exact because EMSA-PKCS1-v1_5 (RFC 8017 9.2) is deterministic: same key + same
  message + same digest = same signature. Any difference is a padding or modexp bug.
- PSS cannot be byte-exact: EMSA-PSS (RFC 8017 9.1) injects a random salt, so two correct signatures
  over the same message differ. Correctness is "openssl verifies it" plus the reverse round-trip.
- `n` / `d` are extracted from openssl here only because DER private-key parsing is plan phase R3.
  Once R3 lands, the signer reads the key file directly and these hex args go away.
