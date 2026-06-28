# ADR-047 (proposal record)

> This is part of 0.5.x

Lean note. The full decision lives in `docs/adr-en.md` / `docs/adr-id.md` (ADR-047). This file
records the rnd-only rationale not carried into the public ADR.

## Objective
Expose TLS bind options as a logger-style object, `zix.Tls.Context`, instead of more flat `tls_*`
fields on each HTTP config.

## Decision (summary)
- `zix.Tls.Context` (the loaded cert / key + validated policy, the SSL_CTX analog) + plain
  `Tls.Context.Config`, built by `Tls.Context.init(allocator, io, config)`.
- HTTP config field `tls: ?*Tls.Context = null`. Non-null = the https opt-in gate.
- Typed enum slices for curves / ciphers (compile-checked), validated to the implemented set at
  init (unsupported value = startup error, never a silent no-op).
- Version floor / ceiling gates the serve path. ECDHE-only, so no dhparam field. Resumption deferred.

## rnd-only rationale (kept OUT of the public ADR)
- The intermediate-config posture this mirrors (the common reverse-proxy TLS reference) is the
  modern-secure baseline. zix verifies that posture on-box (see `rnd/0.5.x/verify-tls-posture.sh`)
  with the ECDHE-only set, so the dhparam knob those proxies expose is intentionally dropped: it
  only parameterizes finite-field DHE, which zix does not negotiate, and the key-exchange strength
  comes from the EC curve, not a DH group file.
- The public ADR justifies the same choices on technical merit only (forward secrecy, AEAD,
  ECDHE-only), per the internal-only grade policy.

## One config type, two front-ends
The typed library path and the planned `zixer` text-config parser both produce a
`Tls.Context.Config`. Building the typed core first makes `zixer` strictly easier (the colon-string
to enum mapping becomes the parser's job, layered on top). See the roadmap `zixer` section.

## Gate
unit-test + examples + test-runner-all (59 protocols), green on Zig 0.16 and 0.17.
