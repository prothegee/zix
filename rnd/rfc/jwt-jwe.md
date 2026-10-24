# JWT and JWE Reference Set

Local copies of the specs behind the JWT sign, verify, claim check, and
algorithm list. Every file comes from `https://www.rfc-editor.org/rfc/`.

<br>

## Core flow

| Item | RFC | Where |
| :- | :- | :- |
| Sign | 7515 | 5.1 (compute the signature or MAC) |
| Verify | 7515 | 5.2 (validate the signature or MAC) |
| JWE encrypt and decrypt | 7516 | 5.1, 5.2 |
| Worked examples for every flow | 7520 | 3 (keys), 4 (JWS), 5 (JWE) |

<br>

## Claims

| Item | RFC | Where |
| :- | :- | :- |
| `iss` | 7519 | 4.1.1 |
| | 8725 | 3.8 (issuer and subject validation) |
| `sub` | 7519 | 4.1.2 |
| | 8725 | 3.8 |
| `aud` | 7519 | 4.1.3 |
| | 8725 | 3.9 |
| `exp` | 7519 | 4.1.4 |
| `nbf` | 7519 | 4.1.5 |
| `iat` | 7519 | 4.1.6 |
| `jti` | 7519 | 4.1.7 |
| `typ` | 7515 | 4.1.9 (JOSE header parameter) |
| | 7519 | 5.1 (JWT header parameter) |
| | 8725 | 3.11 (explicit typing) |
| | 9068 | 2.1 and 4 (the `at+jwt` value and how to reject a mismatch) |

`nbf` appears twice in the task list. It is one claim, covered by RFC 7519
section 4.1.5.

<br>

## Algorithms

| Item | RFC | Where |
| :- | :- | :- |
| HS256, HS384, HS512 | 7518 | 3.2 |
| | 2104 | 2 (HMAC construction) |
| | 6234 | 6 (SHA-2 hashing), 7.1 (HMAC-SHA) |
| RS256, RS384, RS512 | 7518 | 3.3 |
| | 8017 | 8.2 (RSASSA-PKCS1-v1_5) |
| PS256, PS384, PS512 | 7518 | 3.5 |
| | 8017 | 8.1 (RSASSA-PSS) |
| ES256, ES384, ES512 | 7518 | 3.4 |
| | 6979 | 3.2 (deterministic ECDSA nonce) |
| | 5480 | 2 (EC public key in X.509) |
| ES256K | 8812 | 3.1, 3.2 (secp256k1 keys and signatures), 4.3, 4.4 (registrations) |
| EdDSA | 8037 | 3.1 (algorithm identifier) |
| Ed25519, Ed448 | 8037 | 3.2, 4, Appendix A (keys, signing, validation) |
| ML-DSA-44, ML-DSA-65, ML-DSA-87 | 9964 | 3 (AKP key type), 5 (algorithms), 8.1.4, 8.1.6 (registrations) |

`EdDSA` is the JOSE algorithm identifier. `Ed25519` and `Ed448` are the
curves it selects, so both names point at the same RFC.

<br>

## Supporting specs

| RFC | Title | Used for |
| :- | :- | :- |
| 4648 | Base64url | 5 (the unpadded encoding used by every JWS and JWT part) |
| 7517 | JWK | Key representation shared by all algorithms |
| 7638 | JWK Thumbprint | Stable key id, useful for `kid` and key lookup |
| 7800 | JWT Confirmation | `cnf` claim for proof of possession |
| 8259 | JSON | 4 (objects and duplicate member names), 6 (number precision) |
| 8725 | JWT Best Current Practices | Algorithm pinning, typing, claim validation |
| 9068 | JWT Profile for OAuth 2.0 Access Tokens | `at+jwt`, `typ` check, claim rules |
| 6750 | OAuth 2.0 Bearer Token | How a JWT travels in `Authorization` |
| 9881 | X.509 Algorithm Identifiers for ML-DSA | Certificate side of ML-DSA keys |

<br>

## Reading order

1. 7519 for the claim set.
2. 7515 for sign and verify.
3. 7518 for the HMAC, RSA, and ECDSA identifiers.
4. 8037, 8812, and 9964 for the three non-classic families.
5. 8725 last, as the checklist of what to reject.
