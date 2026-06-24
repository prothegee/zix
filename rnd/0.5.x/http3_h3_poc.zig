//! HTTP/3 PoC, phase H3 (http3-plan.md): RFC 9114 section 5.2 / 7.2.6 (GOAWAY), 7.2.7 (MAX_PUSH_ID)
//! and 8.1 (HTTP/3 error codes).
//!
//! Note:
//! - H1 framed the streams, H2 validated the messages. H3 covers connection lifecycle and the error
//!   vocabulary: GOAWAY identifiers only ever decrease (a larger one is H3_ID_ERROR), MAX_PUSH_ID is
//!   a client-only frame whose value only increases, PUSH_PROMISE is server-only, and the full set
//!   of HTTP/3 error codes is fixed.
//! - The oracle is the RFC text: 5.2 fixes GOAWAY monotonicity, 7.2.7 fixes that a server MUST NOT
//!   send MAX_PUSH_ID (a peer receiving the wrong-direction frame raises H3_FRAME_UNEXPECTED), and
//!   8.1 fixes the seventeen error code values plus the reserved (grease) range that maps to
//!   H3_NO_ERROR. State and code values are exercised in process.
//! - This closes the deterministic HTTP/3 framing layer; the live curl --http3 round trip comes with
//!   Layer I.
//!
//! Run:    zig run rnd/0.5.x/http3_h3_poc.zig
//! Verify: bash rnd/0.5.x/verify-http3-h3.sh

const std = @import("std");

// --------------------------------------------------------------- //

/// The HTTP/3 frame types relevant to direction rules (RFC 9114 7.2).
const FrameType = enum { data, headers, cancel_push, settings, push_promise, goaway, max_push_id };

/// Which side of the connection an endpoint is (RFC 9114 7.2.7).
const Role = enum { client, server };

/// Whether a frame type may be SENT by the given role (RFC 9114 7.2.5 / 7.2.7). MAX_PUSH_ID is
/// client-only and PUSH_PROMISE is server-only; a frame from the wrong side is H3_FRAME_UNEXPECTED
/// at the receiver.
fn frameSendableBy(frame: FrameType, sender: Role) bool {
    return switch (frame) {
        .max_push_id => sender == .client,
        .push_promise => sender == .server,
        else => true,
    };
}

// --------------------------------------------------------------- //

/// The identifier-ordering error (RFC 9114 5.2 / 7.2.7): H3_ID_ERROR.
const IdError = error{IdError};

/// Tracks received GOAWAY identifiers (RFC 9114 5.2): each MUST NOT exceed any previous one. A larger
/// identifier is H3_ID_ERROR.
const GoawayTracker = struct {
    last: ?u64 = null,

    fn receive(self: *GoawayTracker, id: u64) IdError!void {
        if (self.last) |prev| {
            if (id > prev) return error.IdError;
        }
        self.last = id;
    }
};

/// Tracks the push limit set by MAX_PUSH_ID (RFC 9114 7.2.7): the value only increases. A smaller
/// value is H3_ID_ERROR.
const MaxPushIdTracker = struct {
    current: ?u64 = null,

    fn update(self: *MaxPushIdTracker, id: u64) IdError!void {
        if (self.current) |prev| {
            if (id < prev) return error.IdError;
        }
        self.current = id;
    }
};

// --------------------------------------------------------------- //

/// The HTTP/3 error codes (RFC 9114 8.1).
const Http3Error = enum(u64) {
    no_error = 0x0100,
    general_protocol_error = 0x0101,
    internal_error = 0x0102,
    stream_creation_error = 0x0103,
    closed_critical_stream = 0x0104,
    frame_unexpected = 0x0105,
    frame_error = 0x0106,
    excessive_load = 0x0107,
    id_error = 0x0108,
    settings_error = 0x0109,
    missing_settings = 0x010a,
    request_rejected = 0x010b,
    request_cancelled = 0x010c,
    request_incomplete = 0x010d,
    message_error = 0x010e,
    connect_error = 0x010f,
    version_fallback = 0x0110,
};

/// Whether an error code is in the reserved (grease) range 0x1f * N + 0x21 (RFC 9114 8.1), which a
/// receiver MUST treat as equivalent to H3_NO_ERROR.
fn isReservedErrorCode(code: u64) bool {
    if (code < 0x21) return false;

    return (code - 0x21) % 0x1f == 0;
}

// --------------------------------------------------------------- //

/// Report a boolean expectation and flag a failure.
fn expect(failures: *usize, name: []const u8, ok: bool) void {
    if (ok) {
        std.debug.print("  ok    {s}\n", .{name});
    } else {
        std.debug.print("  FAIL  {s}\n", .{name});
        failures.* += 1;
    }
}

pub fn main() !void {
    var failures: usize = 0;

    std.debug.print("RFC 9114 5.2: GOAWAY identifier monotonicity\n", .{});

    var goaway = GoawayTracker{};
    try goaway.receive(100);
    expect(&failures, "first GOAWAY (100) ok", goaway.last.? == 100);
    try goaway.receive(60);
    expect(&failures, "lower GOAWAY (60) ok", goaway.last.? == 60);
    try goaway.receive(60);
    expect(&failures, "equal GOAWAY (60) ok", goaway.last.? == 60);
    expect(&failures, "larger GOAWAY (80) -> H3_ID_ERROR", goaway.receive(80) == error.IdError);

    std.debug.print("RFC 9114 7.2.7 / 7.2.5: frame direction\n", .{});

    expect(&failures, "MAX_PUSH_ID sendable by client", frameSendableBy(.max_push_id, .client));
    expect(&failures, "server MUST NOT send MAX_PUSH_ID", !frameSendableBy(.max_push_id, .server));
    expect(&failures, "PUSH_PROMISE sendable by server", frameSendableBy(.push_promise, .server));
    expect(&failures, "client MUST NOT send PUSH_PROMISE", !frameSendableBy(.push_promise, .client));

    std.debug.print("RFC 9114 7.2.7: MAX_PUSH_ID only increases\n", .{});

    var max_push = MaxPushIdTracker{};
    try max_push.update(10);
    try max_push.update(20);
    expect(&failures, "MAX_PUSH_ID increase (10 -> 20) ok", max_push.current.? == 20);
    expect(&failures, "MAX_PUSH_ID decrease (20 -> 5) -> H3_ID_ERROR", max_push.update(5) == error.IdError);

    std.debug.print("RFC 9114 8.1: HTTP/3 error codes\n", .{});

    expect(&failures, "H3_NO_ERROR = 0x0100", @intFromEnum(Http3Error.no_error) == 0x0100);
    expect(&failures, "H3_GENERAL_PROTOCOL_ERROR = 0x0101", @intFromEnum(Http3Error.general_protocol_error) == 0x0101);
    expect(&failures, "H3_INTERNAL_ERROR = 0x0102", @intFromEnum(Http3Error.internal_error) == 0x0102);
    expect(&failures, "H3_STREAM_CREATION_ERROR = 0x0103", @intFromEnum(Http3Error.stream_creation_error) == 0x0103);
    expect(&failures, "H3_CLOSED_CRITICAL_STREAM = 0x0104", @intFromEnum(Http3Error.closed_critical_stream) == 0x0104);
    expect(&failures, "H3_FRAME_UNEXPECTED = 0x0105", @intFromEnum(Http3Error.frame_unexpected) == 0x0105);
    expect(&failures, "H3_FRAME_ERROR = 0x0106", @intFromEnum(Http3Error.frame_error) == 0x0106);
    expect(&failures, "H3_EXCESSIVE_LOAD = 0x0107", @intFromEnum(Http3Error.excessive_load) == 0x0107);
    expect(&failures, "H3_ID_ERROR = 0x0108", @intFromEnum(Http3Error.id_error) == 0x0108);
    expect(&failures, "H3_SETTINGS_ERROR = 0x0109", @intFromEnum(Http3Error.settings_error) == 0x0109);
    expect(&failures, "H3_MISSING_SETTINGS = 0x010a", @intFromEnum(Http3Error.missing_settings) == 0x010a);
    expect(&failures, "H3_REQUEST_REJECTED = 0x010b", @intFromEnum(Http3Error.request_rejected) == 0x010b);
    expect(&failures, "H3_REQUEST_CANCELLED = 0x010c", @intFromEnum(Http3Error.request_cancelled) == 0x010c);
    expect(&failures, "H3_REQUEST_INCOMPLETE = 0x010d", @intFromEnum(Http3Error.request_incomplete) == 0x010d);
    expect(&failures, "H3_MESSAGE_ERROR = 0x010e", @intFromEnum(Http3Error.message_error) == 0x010e);
    expect(&failures, "H3_CONNECT_ERROR = 0x010f", @intFromEnum(Http3Error.connect_error) == 0x010f);
    expect(&failures, "H3_VERSION_FALLBACK = 0x0110", @intFromEnum(Http3Error.version_fallback) == 0x0110);

    // The reserved grease codes (0x1f * N + 0x21) map to H3_NO_ERROR; a real code does not.
    expect(&failures, "0x21 is a reserved (grease) code", isReservedErrorCode(0x21));
    expect(&failures, "0x40 is a reserved (grease) code", isReservedErrorCode(0x40));
    expect(&failures, "H3_FRAME_UNEXPECTED is not a grease code", !isReservedErrorCode(0x0105));

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("PASS: all RFC 9114 H3 GOAWAY / direction / error-code checks hold\n", .{});
    } else {
        std.debug.print("FAIL: {d} check(s) failed\n", .{failures});
        std.process.exit(1);
    }
}
