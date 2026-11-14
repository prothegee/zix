//! ZIX http1 tls feed
//!
//! ### file: src/zix/tcp/http1/tls_feed.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What the TLS paths do with a request as its decrypted bytes arrive: the
//! feed state, the decision step, and the serve lengths.
//!
//! ### note:
//!
//! Only the decision lives here. Reading, decrypting, and writing stay with the
//! two TLS paths (tls_mux for .EPOLL and .URING, tls_serve for .ASYNC).
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

/// Request bytes held across TLS records for one connection.
pub const State = @import("tls_feed/State.zig");

/// What to do with the request at the front of the buffer.
pub const Step = @import("tls_feed/step.zig").Step;

/// The lengths a serve decision carries.
pub const Serve = @import("tls_feed/Serve.zig");

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http1: tls_feed, a fresh state holds nothing" {
    const state: State = .{};

    try std.testing.expect(!state.inFlight());
}

