//! TLZ tls12 client ServerFlight
//!
//! ### file: src/tlz/src/tls12/client/ServerFlight.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The parts of the TLS 1.2 server flight 1 the client needs: the server random,
//! the certificate, and the signed ServerKeyExchange.
//!
//! ### note:
//!
//! Every slice is a view into the flight bytes, so it lives only as long as them.
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

// --------------------------------------------------------- //
// Fields:

/// The ServerHello random.
server_random: [32]u8 = undefined,
/// A ServerHello was seen.
has_server_hello: bool = false,
/// The server ECDHE point (uncompressed secp256r1).
server_point: []const u8 = &.{},
/// The end-entity certificate DER.
cert_der: []const u8 = &.{},
/// The signed ServerECDHParams: curve type, named curve, point.
ske_params: []const u8 = &.{},
/// The DER ECDSA signature over client_random ++ server_random ++ ske_params.
ske_sig: []const u8 = &.{},

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// Every message `finish` needs was in the flight.
///
/// Return:
/// - bool
pub fn isComplete(self: *const Self) bool {
    if (!self.has_server_hello) return false;
    if (self.cert_der.len == 0) return false;

    return self.server_point.len > 0 and self.ske_sig.len > 0;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn completeFlight() Self {
    return .{
        .has_server_hello = true,
        .server_point = "point",
        .cert_der = "cert",
        .ske_params = "params",
        .ske_sig = "sig",
    };
}

test "tlz tls12 client: ServerFlight, empty flight is incomplete" {
    const flight: Self = .{};

    try std.testing.expect(!flight.isComplete());
}

test "tlz tls12 client: ServerFlight, all messages make it complete" {
    const flight = completeFlight();

    try std.testing.expect(flight.isComplete());
}

test "tlz tls12 client: ServerFlight, without a certificate is incomplete" {
    var flight = completeFlight();
    flight.cert_der = &.{};

    try std.testing.expect(!flight.isComplete());
}

test "tlz tls12 client: ServerFlight, without a ServerHello is incomplete" {
    var flight = completeFlight();
    flight.has_server_hello = false;

    try std.testing.expect(!flight.isComplete());
}

test "tlz tls12 client: ServerFlight, without a key exchange is incomplete" {
    var flight = completeFlight();
    flight.ske_sig = &.{};

    try std.testing.expect(!flight.isComplete());
}

