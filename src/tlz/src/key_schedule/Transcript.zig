//! TLZ key schedule Transcript
//!
//! ### file: src/tlz/src/key_schedule/Transcript.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Running Transcript-Hash over the handshake messages (RFC 8446 section 4.4.1).
//!
//! ### note:
//!
//! `current` reads a snapshot, so the running hash keeps going after it.
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
const key_schedule = @import("../key_schedule.zig");

const Sha256 = key_schedule.Sha256;
const Secret = key_schedule.Secret;

// --------------------------------------------------------- //
// Fields:

/// The running SHA-256 state over every message fed so far.
hasher: Sha256,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// An empty transcript.
///
/// Usage:
/// ```zig
/// var transcript: Transcript = .init();
///
/// transcript.update(client_hello);
/// transcript.update(server_hello);
///
/// const hash = transcript.current();
/// ```
///
/// Return:
/// - Self
pub fn init() Self {
    return .{
        .hasher = Sha256.init(.{}),
    };
}

/// Feed one handshake message, header included.
///
/// Param:
/// message - []const u8 (the whole handshake message bytes)
///
/// Return:
/// - void
pub fn update(self: *Self, message: []const u8) void {
    self.hasher.update(message);
}

/// The transcript hash at this point, without consuming the running state.
///
/// Return:
/// - Secret
pub fn current(self: Self) Secret {
    var snapshot = self.hasher;

    return snapshot.finalResult();
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn sha256Of(bytes: []const u8) Secret {
    var out: Secret = undefined;
    Sha256.hash(bytes, &out, .{});

    return out;
}

test "tlz key_schedule: Transcript, empty hash is SHA-256 of nothing" {
    const transcript: Self = .init();

    try std.testing.expectEqualSlices(u8, &sha256Of(""), &transcript.current());
}

test "tlz key_schedule: Transcript, updates hash as one concatenation" {
    var transcript: Self = .init();

    transcript.update("client");
    transcript.update("server");

    try std.testing.expectEqualSlices(u8, &sha256Of("clientserver"), &transcript.current());
}

test "tlz key_schedule: Transcript, current does not consume the state" {
    var transcript: Self = .init();
    transcript.update("client");

    const first = transcript.current();
    const second = transcript.current();

    try std.testing.expectEqualSlices(u8, &first, &second);
}

test "tlz key_schedule: Transcript, update after current keeps hashing" {
    var transcript: Self = .init();
    transcript.update("client");

    _ = transcript.current();
    transcript.update("server");

    try std.testing.expectEqualSlices(u8, &sha256Of("clientserver"), &transcript.current());
}

test "tlz key_schedule: Transcript, empty update changes nothing" {
    var transcript: Self = .init();

    transcript.update("");

    try std.testing.expectEqualSlices(u8, &sha256Of(""), &transcript.current());
}

