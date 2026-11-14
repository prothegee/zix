//! TLZ example cert_verify
//!
//! ### file: src/tlz/examples/cert_verify.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Peer certificate checks: PEM to DER, a leaf to intermediate to root chain, the host
//! name, and the failures a client must refuse.
//!
//! ### note:
//!
//! The chain is a test fixture (root, intermediate, `localhost` leaf), valid
//! 2026-06-23 to 2036-06-20. Never trust it outside this example.
//! Build with `zig build example-cert_verify` from `src/tlz`.
//!
//! ---------------------------------------------------------
//!
//! ### licenses:
//!
//! - BSD-3-Clause
//!
//! ### copyright:
//!
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//!
//! ### contributors:
//!
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");
const tlz = @import("tlz");

// --------------------------------------------------------- //
// Private:

/// The trust anchor: a self-signed root CA.
const ROOT_PEM =
    \\-----BEGIN CERTIFICATE-----
    \\MIIBlTCCATugAwIBAgIUQPeXBsmacAjl3aCBXk4xH55wL1EwCgYIKoZIzj0EAwIw
    \\GDEWMBQGA1UEAwwNeml4LXRlc3Qtcm9vdDAeFw0yNjA2MjMwNzM2MDFaFw0zNjA2
    \\MjAwNzM2MDFaMBgxFjAUBgNVBAMMDXppeC10ZXN0LXJvb3QwWTATBgcqhkjOPQIB
    \\BggqhkjOPQMBBwNCAARKiewMEpxQbZsfksWyj5Mop7BjVWzWTC1YAtsOZMRW/JAh
    \\nXi2z9oQAnQj64wcSohr/iu5tKp8upvUSfEX9XwEo2MwYTAdBgNVHQ4EFgQUNW86
    \\wkjj4qi7m9BHxeYhmq2n8CAwHwYDVR0jBBgwFoAUNW86wkjj4qi7m9BHxeYhmq2n
    \\8CAwDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMCAQYwCgYIKoZIzj0EAwID
    \\SAAwRQIhAOo73UObJ0pdDveZOnDxjZE+eEDWadG0TJ64QUnresCGAiA4BOxYgYQd
    \\OnNOThoFIxxZW29Doco+bw0DmABPhdAEfg==
    \\-----END CERTIFICATE-----
    \\
;

/// The intermediate CA, signed by the root (pathLen 0).
const INTERMEDIATE_PEM =
    \\-----BEGIN CERTIFICATE-----
    \\MIIBnzCCAUagAwIBAgIUBnayX2xPEu2buHP4OgB9uE6POEYwCgYIKoZIzj0EAwIw
    \\GDEWMBQGA1UEAwwNeml4LXRlc3Qtcm9vdDAeFw0yNjA2MjMwNzM2MDFaFw0zNjA2
    \\MjAwNzM2MDFaMCAxHjAcBgNVBAMMFXppeC10ZXN0LWludGVybWVkaWF0ZTBZMBMG
    \\ByqGSM49AgEGCCqGSM49AwEHA0IABCR6bJH4U37xXPcWcFWROP26DSoYZbm4Cf0X
    \\gOIns6So1WyV58gzEbdsKrOGG3sdTRtTXI9npbHo0ytUs4BkyZmjZjBkMBIGA1Ud
    \\EwEB/wQIMAYBAf8CAQAwDgYDVR0PAQH/BAQDAgEGMB0GA1UdDgQWBBTWmcuRSXzH
    \\+YG8yvamMqHu4DbVKzAfBgNVHSMEGDAWgBQ1bzrCSOPiqLub0EfF5iGarafwIDAK
    \\BggqhkjOPQQDAgNHADBEAiAKCdxE2WFDBQhM3HCB1xgaRJfQ7peH0uX4GW/n5QxQ
    \\/QIgPpfmvh1nAGcp84wVyvEW7IsL58tKEB4fnsxx1StDXHE=
    \\-----END CERTIFICATE-----
    \\
;

/// The end-entity certificate for `localhost`, signed by the intermediate.
const LEAF_PEM =
    \\-----BEGIN CERTIFICATE-----
    \\MIIBrTCCAVKgAwIBAgIUct2f6apCjOIqy7fmFGIx5mJppsAwCgYIKoZIzj0EAwIw
    \\IDEeMBwGA1UEAwwVeml4LXRlc3QtaW50ZXJtZWRpYXRlMB4XDTI2MDYyMzA3MzYw
    \\MVoXDTM2MDYyMDA3MzYwMVowFDESMBAGA1UEAwwJbG9jYWxob3N0MFkwEwYHKoZI
    \\zj0CAQYIKoZIzj0DAQcDQgAEfB1bHKh++zkvaPscE9ou3MjX6woXPrfOIxdKcAkU
    \\LaljFDQE0IY0/ZpFUllNQF/oe/GDwIuXOtGrAInUPhlJv6N2MHQwDAYDVR0TAQH/
    \\BAIwADAOBgNVHQ8BAf8EBAMCB4AwFAYDVR0RBA0wC4IJbG9jYWxob3N0MB0GA1Ud
    \\DgQWBBRg2WhbCjWs+qmXXmKj0mYCNKLqBzAfBgNVHSMEGDAWgBTWmcuRSXzH+YG8
    \\yvamMqHu4DbVKzAKBggqhkjOPQQDAgNJADBGAiEA7hsfxIsOOzWC0PvNvBRoYyY4
    \\FuG1R/lKulfCWyjNYE0CIQDHzbofnmPoL/nMMeGWcRNo/snPPwkreVQC+Zwo5F9S
    \\Jw==
    \\-----END CERTIFICATE-----
    \\
;

/// A time far past the chain notAfter, to show the expiry check.
const FAR_FUTURE_SEC: i64 = 2_200_000_000;

/// The largest DER one fixture certificate decodes to.
const MAX_CERT_DER = 1024;

/// Print one check and whether it passed.
///
/// Param:
/// what - []const u8 (the check, as printed)
/// outcome - anytype (the error union `void` the check returned)
///
/// Return:
/// - void
fn report(what: []const u8, outcome: anytype) void {
    if (outcome) |_| {
        std.debug.print("{s}: ok\n", .{what});
    } else |err| {
        std.debug.print("{s}: refused ({t})\n", .{ what, err });
    }
}

// --------------------------------------------------------- //
// Public:

pub fn main(init: std.process.Init) !void {
    const now_sec = std.Io.Timestamp.now(init.io, .real).toSeconds();

    var root_buf: [MAX_CERT_DER]u8 = undefined;
    var intermediate_buf: [MAX_CERT_DER]u8 = undefined;
    var leaf_buf: [MAX_CERT_DER]u8 = undefined;
    const root = try tlz.pemToDer(&root_buf, ROOT_PEM);
    const intermediate = try tlz.pemToDer(&intermediate_buf, INTERMEDIATE_PEM);
    const leaf = try tlz.pemToDer(&leaf_buf, LEAF_PEM);
    const chain = [_][]const u8{
        leaf,
        intermediate,
    };

    // What a client accepts
    report("chain to the root", tlz.verifyChain(&chain, root, now_sec));
    report("host localhost", tlz.verifyCertHostname(leaf, "localhost"));
    report("identity localhost", tlz.verifyCertIdentity(leaf, "localhost"));

    // What a client refuses
    report("chain to the wrong anchor", tlz.verifyChain(&chain, leaf, now_sec));
    report("chain after notAfter", tlz.verifyChain(&chain, root, FAR_FUTURE_SEC));
    report("leaf without its intermediate", tlz.verifyCertChain(leaf, root, now_sec));
    report("host evil.example", tlz.verifyCertHostname(leaf, "evil.example"));
}

