//! ZIX tls session
//!
//! ### file: src/zix/tls/tls_session.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Resumable sans-I/O TLS server session over tlz, for the multiplexed TLS loops:
//! the session record and its phase, outcome, and feed result.
//!
//! ### note:
//!
//! The epoll or io_uring loop owns the socket. The session only advances the TLS
//! state machine, so one worker multiplexes many TLS connections.
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

/// One TLS server connection's resumable state.
pub const Session = @import("tls_session/Session.zig");

/// Where the handshake and data state machine is.
pub const Phase = @import("tls_session/phase.zig").Phase;

/// What a feed produced, for the dispatch loop to act on.
pub const Outcome = @import("tls_session/outcome.zig").Outcome;

/// Bytes to send, plaintext, and outcome of one feed.
pub const FeedResult = @import("tls_session/FeedResult.zig");

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix tls: tls_session, exports the session record" {
    try std.testing.expect(@hasDecl(Session, "feed"));
    try std.testing.expect(@hasDecl(Session, "encrypt"));
}

