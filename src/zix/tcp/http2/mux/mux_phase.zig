//! ZIX Http2 mux mux_phase
//!
//! ### file: src/zix/tcp/http2/mux/mux_phase.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Where a mux connection is in its handshake, before and after the preface.
//!
//! ### note:
//!
//! n/a
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
// Public:

/// Handshake phase of one mux connection.
pub const MuxPhase = enum {
    /// Nothing read yet: the preface or an HTTP/1.1 upgrade may follow.
    await_preface,
    /// The first bytes were not the preface: reading an HTTP/1.1 upgrade head.
    await_upgrade,
    /// 101 was sent: waiting for the preface that follows an upgrade.
    await_preface2,
    /// Preface accepted: frames flow.
    h2,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2 mux: mux_phase, a connection starts awaiting the preface" {
    const phase: MuxPhase = .await_preface;

    try std.testing.expect(phase != .h2);
}

