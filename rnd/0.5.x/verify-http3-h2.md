# Verify: HTTP/3 request / response semantics (http3-plan.md phase H2)

H1 framed the streams. H2 validates the message a HEADERS frame carries. HTTP/3 is deliberately
strict here, because being permissive exposes implementations to request-smuggling and related
attacks. Any violation is malformed, a stream error of type H3_MESSAGE_ERROR.

## Oracle

RFC 9114 section 4.1.2 + 4.2 + 4.3:

- 4.3.1 fixes the request pseudo-headers: :method, :scheme, :path (and :authority unless the method
  is CONNECT, which instead omits :scheme and :path). 4.3.2 fixes the single response pseudo-header
  :status. Missing a mandatory one, or carrying the other role's pseudo-headers, is malformed.
- 4.2 fixes that field names MUST be lowercase (an uppercase name is malformed) and that
  connection-specific fields (connection, keep-alive, transfer-encoding, and similar) are prohibited.
- 4.1.2 enumerates the malformed conditions: a prohibited or unknown pseudo-header, a pseudo-header
  after a regular field, and a Content-Length that does not equal the sum of the DATA frame lengths.

The PoC validates well-formed request / CONNECT / response messages and exercises each malformed
path. No external tool is used at this layer; this is message-level validation above QPACK decode.

## Run

```sh
bash rnd/0.5.x/verify-http3-h2.sh
```

## Expect

The PoC checks 16 values and prints `ok` for each:

| Group | Checks |
| :- | :- |
| 4.3 well-formed | request, CONNECT, response |
| 4.3 mandatory pseudo | missing :method / :path / :status, CONNECT with :path |
| 4.1.2 / 4.2 prohibited | uppercase, pseudo-after-field, unknown pseudo, cross-role pseudo, connection-specific |
| 4.1.2 Content-Length | matches DATA sum, mismatch rejected |

On success the script prints `PASS` and exits 0. Any failure prints `FAIL` and exits non-zero.
