//! Integration tests: Tls.Context loads an RSA certificate (rsa-plan.md R6) and the loaded key
//! signs a valid rsa_pss_rsae_sha256 signature (R5), verified through std's RSA verify (the exact
//! check a TLS 1.3 client runs on the server CertificateVerify).
//!
//! RSA is a server-side capability for the https path. The default cert type is unchanged (ECDSA
//! P-256), an RSA cert simply selects the RSA signing identity. RSA requires TLS 1.3, the 1.2
//! ServerKeyExchange path is ECDSA-only.

const std = @import("std");
const zix = @import("zix");

const StdRsa = std.crypto.Certificate.rsa;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// A self-signed RSA-2048 certificate and its matching PKCS#8 key (openssl), written to temp files
/// so Tls.Context.init reads them exactly as it would a deployed cert.
const cert_pem =
    \\-----BEGIN CERTIFICATE-----
    \\MIIDJTCCAg2gAwIBAgIUZSmgyTpuzC6HiEGm54ajWJBtMvowDQYJKoZIhvcNAQEL
    \\BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI2MDYyMzE3NDQwOFoXDTM2MDYy
    \\MDE3NDQwOFowFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF
    \\AAOCAQ8AMIIBCgKCAQEA4iv7pZYRgU/zI7NXEN2+8aiALR8DI7k8Z1J3uNqlN3FK
    \\xHh9v41o14xHgTAarfE2KdRVaQ4PrtgxlCWnWvq7RbD1WZA/9Ox1Bl2H8muocHcD
    \\qsI5vn3SPoyCKTPjdbei5/nle+RiLvChK7kUFU7Ed0c/LjHCDf2qb1z9U7rNmNmS
    \\IQCl/b5Ng7y+vu4Ai8ytMCZnUN+GhhMPPTEX0C1Zk6Rb2UidgfNXcWPiHYG7IYmW
    \\25++qc3R+E78SDsA6VMVteqmO1V2RKzLUUvY52rzKSAdbE5GSymciJKMFqnnlViE
    \\BvOUa3jsIhGMsEVGJ4SOOGAcX9F5oK9cegpyd2rcQwIDAQABo28wbTAdBgNVHQ4E
    \\FgQUVovuoiFFdtAEPMt8hFAlINHRzy0wHwYDVR0jBBgwFoAUVovuoiFFdtAEPMt8
    \\hFAlINHRzy0wDwYDVR0TAQH/BAUwAwEB/zAaBgNVHREEEzARgglsb2NhbGhvc3SH
    \\BH8AAAEwDQYJKoZIhvcNAQELBQADggEBAH+kN8hzDd0qsfPaAMAY3uPRWdJeLFn0
    \\4BImvckbraTbUOAWnJENavjPwVZya9B62IeyoJtl5ewMkNNQJosxNL3sLm7kLfTt
    \\HHDg8Ep+JT3kuRT40qPca7jbda2mSOAt4EZJVxP7ENRlUsHjnid7k/H/BO8P8ekV
    \\HVsIi+BHOVwgXX96BHUADp9OT/z61zT4FGKdf2TzRgMsAwYqU34NjK8YwbOQvBX7
    \\zrFyL6Y5KYxPFo4dPlzmjcdMMYuXM7Huqh8rrCrlV/ZMX//ZoWTPlrLpZL2GixJX
    \\sEjyFYeGbxcxrxhvLWggDncYcdy+NX2QC01zMOzakjlCXpNqugRv3hE=
    \\-----END CERTIFICATE-----
;

const key_pem =
    \\-----BEGIN PRIVATE KEY-----
    \\MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDiK/ullhGBT/Mj
    \\s1cQ3b7xqIAtHwMjuTxnUne42qU3cUrEeH2/jWjXjEeBMBqt8TYp1FVpDg+u2DGU
    \\Jada+rtFsPVZkD/07HUGXYfya6hwdwOqwjm+fdI+jIIpM+N1t6Ln+eV75GIu8KEr
    \\uRQVTsR3Rz8uMcIN/apvXP1Tus2Y2ZIhAKX9vk2DvL6+7gCLzK0wJmdQ34aGEw89
    \\MRfQLVmTpFvZSJ2B81dxY+IdgbshiZbbn76pzdH4TvxIOwDpUxW16qY7VXZErMtR
    \\S9jnavMpIB1sTkZLKZyIkowWqeeVWIQG85RreOwiEYywRUYnhI44YBxf0Xmgr1x6
    \\CnJ3atxDAgMBAAECggEACaafz9KF/7MWKG1UJ0OXDL/IbGR44VLbqXsC4c/uod2D
    \\N7v+fah+k0gImxIe6VI0IffOBzQS5j6SawRqTj8Js7EX3xEBMaXPXoyqKuV+JAJo
    \\FSbBiQfca0/alACDUbgayvRGXxGBQQiCkBePLFOWnZJcN0/nPGqZFbRtmN+NO1rk
    \\zTD46uKfBAFMKZLbWrK8plECMfea5h+/ysnfhpZXv5nAXuPY6cvwgDTZvphQdB4l
    \\4mjAtuI6oEYUL4CVga1NE57vC02RxJBwylmxznJyJcRdLl52kSgOMU3xV9isrrZT
    \\88s9Ds5ZxtGqaWUmbF+pHW1wxzTmJhrCXxEGtsrmAQKBgQD5u1KiuTlPnnVgIRfT
    \\thzF5pBp6Ynwbw/Q0SMkF/E7yxkPDdLWMY43WIikRj9IyfDnIRxdGEBkprF7/Sm/
    \\ehGVGRDNNT3eRaZ04jLP/EbksO9hF49ro/FlHSaaVrDSAsW3F8HBp8NQC9Sgpdlf
    \\XwnxZsP35wpISF1hWV5be0yWAQKBgQDn2UYCjGCRFdBNdsqxbgGemPBu60/U0leE
    \\T8xg42jN6tO2j0vesKp83NFcAl71NYh7rl8G+WnFJ3DgrjrFAPbTa6VJdnNnpjV+
    \\3o2CSqSTAReFM2khRIZodCbQ3Ad/6P00RnahpciBemQsQKeyGRMrhrkBZbiPIWch
    \\LgBIniOaQwKBgGcmxsVL+K44Z4cjZDIgoNXlnHUC7+UOGtxH5ln8QbpO87TSIuoy
    \\YeneeeJQ2cb5EraFaK/TWpW4fMsYEOx0QVrylYwNl9Z9snnJDO/35liD9PyHvMfb
    \\WdRILC/H6xVz67Lq7y9MWlJv8I3Cs3y/Rt4dcoitOAQPT/Lr9RuYXFQBAoGBAM0U
    \\QXsrlJeBRhnfQ/eiKMiS28ohVyIXVNZyh4QEY8YRO2g2ZJP8jTGZWY8bgcdArRNJ
    \\8ECJCegctRnow49TBQGKLFBI+Ffsi1FHpsBjKiPmSVnHWezVYlaut07z8aZQ/vfo
    \\hDMEI9Fz43vJTQyaZXyQ1MDJq3DfyQtuV03ko/VlAoGBAJiRuT9T8EQO0gJoaS6g
    \\W/+g7A+JUZnqIrCiL9JAaWzOy4TdKtEgbDQsLH1NfVclcnti5C/6wlCqvPcSQtF/
    \\ZGgEuI4ajyq60Un5tOiB1rbJ5sahSLgpM21Ph6kkC6nxTuKfRPpu1+L92SFZBFrX
    \\sIWllpzoV5pFqYoMGir8MZfp
    \\-----END PRIVATE KEY-----
;

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

test "zix integration: Tls.Context loads an RSA cert and signs a valid PSS signature" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cert_path = "/tmp/zix_rsa_integration_cert.pem";
    const key_path = "/tmp/zix_rsa_integration_key.pem";
    try writeFile(io, cert_path, cert_pem);
    try writeFile(io, key_path, key_pem);
    defer std.Io.Dir.cwd().deleteFile(io, cert_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, key_path) catch {};

    var ctx = try zix.Tls.Context.init(std.testing.allocator, io, .{
        .cert_path = cert_path,
        .key_path = key_path,
        .alpn = &.{.HTTP_1_1},
    });
    defer ctx.deinit();

    // R6: the RSA certificate was detected and produced an RSA signing identity.
    switch (ctx.signing_key) {
        .rsa => {},
        else => return error.ExpectedRsaSigningKey,
    }
    try std.testing.expectEqual(@as(u16, 0x0804), @intFromEnum(ctx.signing_key.scheme()));

    // R5: the loaded key signs a PSS signature std verifies (the exact check a TLS client runs).
    const message = "tls 1.3 server certificateverify content stand-in";
    var salt: [32]u8 = undefined;
    @memset(&salt, 0x33);

    var sig_buf: [512]u8 = undefined;
    const sig = try ctx.signing_key.rsa.signPss(message, salt, &sig_buf);

    var n_bytes: [256]u8 = undefined;
    @memcpy(&n_bytes, ctx.signing_key.rsa.modulus());
    const e_bytes = [_]u8{ 0x01, 0x00, 0x01 };
    const public_key = try StdRsa.PublicKey.fromBytes(&e_bytes, &n_bytes);
    try StdRsa.PSSSignature.verify(256, sig[0..256].*, message, public_key, Sha256);
}

/// A self-signed RSA-1024 certificate and matching key, below the 2048-bit minimum, to assert the
/// weak-key rejection in Tls.Context.init.
const weak_cert_pem =
    \\-----BEGIN CERTIFICATE-----
    \\MIICGjCCAYOgAwIBAgIUHaUNgaw6bTEQVHSowUmGRyGrNWQwDQYJKoZIhvcNAQEL
    \\BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI2MDYyMzE3NDYwN1oXDTM2MDYy
    \\MDE3NDYwN1owFDESMBAGA1UEAwwJbG9jYWxob3N0MIGfMA0GCSqGSIb3DQEBAQUA
    \\A4GNADCBiQKBgQC7+vjXemwjXmgAklG2NLVNyhvD7AyoTrgvNUjNpBZuQ8tsWwC/
    \\n0FxImEI/YR51iCr5zb0GJBeq0dMa5iZWTMaCn69E7L9vr56FzEWr3JwDLl+9sev
    \\UhrxsWpTSxcGFJdvqClyqtgAANtdaATZuZTv56vLr1wEM1iAyjn4PficCQIDAQAB
    \\o2kwZzAdBgNVHQ4EFgQUJv3dRrumd5HtHts0d3tIWWiBcXQwHwYDVR0jBBgwFoAU
    \\Jv3dRrumd5HtHts0d3tIWWiBcXQwDwYDVR0TAQH/BAUwAwEB/zAUBgNVHREEDTAL
    \\gglsb2NhbGhvc3QwDQYJKoZIhvcNAQELBQADgYEAs9dZbqQImF7tGSqJmyIHPkB7
    \\vMImfJXUwPxLGR6gLOtYirJLj+3hC6umAJvnTk9u++Augq7IhGTI6J7D33F2wSxd
    \\B/DmkyOPDzTxmuOTZNNf4Xaq+U39bq5ZW2394enTPsz9a73wTQXR2jWD5LYzXF05
    \\NCs6MH6O4g+jR8H5WBU=
    \\-----END CERTIFICATE-----
;

const weak_key_pem =
    \\-----BEGIN PRIVATE KEY-----
    \\MIICdwIBADANBgkqhkiG9w0BAQEFAASCAmEwggJdAgEAAoGBALv6+Nd6bCNeaACS
    \\UbY0tU3KG8PsDKhOuC81SM2kFm5Dy2xbAL+fQXEiYQj9hHnWIKvnNvQYkF6rR0xr
    \\mJlZMxoKfr0Tsv2+vnoXMRavcnAMuX72x69SGvGxalNLFwYUl2+oKXKq2AAA211o
    \\BNm5lO/nq8uvXAQzWIDKOfg9+JwJAgMBAAECgYA7b+WSrGDY5hbYZ2tyw0O4bvlM
    \\f6yY4xsVwjFc5E87WjBN+JBKBp74mLg50X87ztrRv+/+Sm4LoPiQT00W379qJ1rI
    \\1IiAX4XblyXnu5Isq4yaGbhDAZUMNb9cL/OfopMihRQQabb0PuEuKUKz2BP14BBw
    \\w8ruD9zTcZbZ6EReAQJBAOyzhhBmUsk7Qm2pX+cGt6Hv7Y6nUKbJ3VfIptZ1wbL9
    \\Oq9HHHey+eI65E8NloMbIdTHxltff/2n6Z0tPUdjDWECQQDLToks8Ndu5nsHU/07
    \\Y3Cxb8iGwoteM8dAT6TN+f+wweYzSWZ13TkLgonrEobN6e4+TIA5FUaT/Ur4o+zP
    \\ayepAkEAk9L2Og29TAFfVh8+TojqbA7sXHfvrYpKWsVsNGlsY/00Bj0x8StsVbYT
    \\2a8RvaVXNozhOzVkOKUCB/A14fxhYQJBAItyD6aSfsFjNqldE0jjuM0LRfgggeUY
    \\EKdsuTZKLfV32UP+KVfYZ6McYyqoJ2we8rkqUZxVmnYw+nY2QVw3PBkCQGA2o6pB
    \\hGunrRKCu2iYtB3VFlU+fZm/mz9hPnhlOiB/jFgiORxmP/YrbQVCWGrTMOqBBCQr
    \\Id30iXRWGHbxQf0=
    \\-----END PRIVATE KEY-----
;

test "zix integration: an RSA key below 2048 bits is rejected" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cert_path = "/tmp/zix_rsa_integration_weak_cert.pem";
    const key_path = "/tmp/zix_rsa_integration_weak_key.pem";
    try writeFile(io, cert_path, weak_cert_pem);
    try writeFile(io, key_path, weak_key_pem);
    defer std.Io.Dir.cwd().deleteFile(io, cert_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, key_path) catch {};

    try std.testing.expectError(error.RsaKeyTooSmall, zix.Tls.Context.init(std.testing.allocator, io, .{
        .cert_path = cert_path,
        .key_path = key_path,
        .alpn = &.{.HTTP_1_1},
    }));
}
