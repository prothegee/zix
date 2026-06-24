//! HTTP/3 PoC, phase H1 (http3-plan.md): RFC 9114 section 6.2 (stream mapping) and 7.2 (frame
//! definitions), covering the control stream, the SETTINGS-first rule, and the frame-per-stream
//! permission matrix.
//!
//! Note:
//! - QPACK (Layer P) compresses the headers; HTTP/3 (Layer H) is the framing that carries them. H1
//!   is the stream and frame structure: the control stream type, the rule that SETTINGS is the first
//!   frame on it, which frame types each frame value names, which frames are legal on which stream,
//!   and the legal frame order within a request.
//! - The oracle is the RFC text: 6.2.1 fixes the control stream type (0x00) and the
//!   H3_MISSING_SETTINGS / H3_STREAM_CREATION_ERROR rules, 7.2 fixes the seven frame type values,
//!   and the framing rules fix the H3_FRAME_UNEXPECTED cases (a frame on the wrong stream, DATA
//!   before HEADERS, anything after the trailing HEADERS). State machines are exercised in process.
//! - Layer H builds on QPACK and the QUIC transport, but H1 itself is pure framing logic, no crypto.
//!
//! Run:    zig run rnd/0.5.x/http3_h1_poc.zig
//! Verify: bash rnd/0.5.x/verify-http3-h1.sh

const std = @import("std");

// --------------------------------------------------------------- //

/// The HTTP/3 frame types (RFC 9114 7.2). The values are sparse: 0x02 and 0x06 are reserved / used
/// elsewhere, so the set is explicit.
const FrameType = enum(u64) {
    data = 0x00,
    headers = 0x01,
    cancel_push = 0x03,
    settings = 0x04,
    push_promise = 0x05,
    goaway = 0x07,
    max_push_id = 0x0d,
};

/// The HTTP/3 unidirectional stream types (RFC 9114 6.2, QPACK 4.2).
const control_stream: u64 = 0x00;
const push_stream: u64 = 0x01;
const qpack_encoder_stream: u64 = 0x02;
const qpack_decoder_stream: u64 = 0x03;

/// Whether a frame type may appear on the control stream (RFC 9114 7.2). DATA / HEADERS / PUSH_PROMISE
/// on the control stream are H3_FRAME_UNEXPECTED.
fn frameAllowedOnControl(frame: FrameType) bool {
    return switch (frame) {
        .settings, .goaway, .max_push_id, .cancel_push => true,
        .data, .headers, .push_promise => false,
    };
}

/// Whether a frame type may appear on a request stream (RFC 9114 7.2). SETTINGS / GOAWAY /
/// MAX_PUSH_ID / CANCEL_PUSH on a request stream are H3_FRAME_UNEXPECTED.
fn frameAllowedOnRequest(frame: FrameType) bool {
    return switch (frame) {
        .headers, .data, .push_promise => true,
        .settings, .goaway, .max_push_id, .cancel_push => false,
    };
}

// --------------------------------------------------------------- //

/// The control-stream errors (RFC 9114 6.2.1).
const ControlError = error{
    /// The first frame on the control stream was not SETTINGS: H3_MISSING_SETTINGS.
    MissingSettings,
    /// A second control stream was opened: H3_STREAM_CREATION_ERROR.
    StreamCreationError,
};

/// Tracks the control-stream invariants (RFC 9114 6.2.1): exactly one control stream, SETTINGS first.
const ControlStream = struct {
    open: bool = false,
    settings_seen: bool = false,

    /// Open the single control stream. A second one is H3_STREAM_CREATION_ERROR.
    fn open_stream(self: *ControlStream) ControlError!void {
        if (self.open) return error.StreamCreationError;
        self.open = true;
    }

    /// Process a frame on the control stream. The first frame MUST be SETTINGS.
    fn onFrame(self: *ControlStream, frame: FrameType) ControlError!void {
        if (!self.settings_seen and frame != .settings) return error.MissingSettings;
        self.settings_seen = true;
    }
};

// --------------------------------------------------------------- //

/// The position within a request's frame sequence (RFC 9114 4.1): a HEADERS, then optional DATA,
/// then an optional trailing HEADERS, and nothing after.
const RequestState = enum { initial, header_seen, trailer_seen };

/// Advance the request frame sequence (RFC 9114 4.1). A null result is an invalid sequence,
/// H3_FRAME_UNEXPECTED: DATA before HEADERS, or any frame after the trailing HEADERS.
fn requestFrameTransition(state: RequestState, frame: FrameType) ?RequestState {
    return switch (state) {
        .initial => switch (frame) {
            .headers => .header_seen,
            else => null,
        },
        .header_seen => switch (frame) {
            .data => .header_seen,
            .headers => .trailer_seen,
            else => null,
        },
        .trailer_seen => null,
    };
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

    std.debug.print("RFC 9114 7.2: frame type values\n", .{});

    expect(&failures, "DATA = 0x00", @intFromEnum(FrameType.data) == 0x00);
    expect(&failures, "HEADERS = 0x01", @intFromEnum(FrameType.headers) == 0x01);
    expect(&failures, "CANCEL_PUSH = 0x03", @intFromEnum(FrameType.cancel_push) == 0x03);
    expect(&failures, "SETTINGS = 0x04", @intFromEnum(FrameType.settings) == 0x04);
    expect(&failures, "PUSH_PROMISE = 0x05", @intFromEnum(FrameType.push_promise) == 0x05);
    expect(&failures, "GOAWAY = 0x07", @intFromEnum(FrameType.goaway) == 0x07);
    expect(&failures, "MAX_PUSH_ID = 0x0d", @intFromEnum(FrameType.max_push_id) == 0x0d);

    std.debug.print("RFC 9114 6.2: unidirectional stream types\n", .{});

    expect(&failures, "control stream = 0x00", control_stream == 0x00);
    expect(&failures, "push stream = 0x01", push_stream == 0x01);
    expect(&failures, "QPACK encoder / decoder = 0x02 / 0x03", qpack_encoder_stream == 0x02 and qpack_decoder_stream == 0x03);

    std.debug.print("RFC 9114 6.2.1: control stream + SETTINGS first\n", .{});

    // SETTINGS as the first frame is accepted; a second control stream is rejected.
    var control = ControlStream{};
    try control.open_stream();
    try control.onFrame(.settings);
    expect(&failures, "SETTINGS first on control stream ok", control.settings_seen);
    try control.onFrame(.goaway);
    expect(&failures, "GOAWAY after SETTINGS ok", control.settings_seen);
    expect(&failures, "second control stream -> H3_STREAM_CREATION_ERROR", control.open_stream() == error.StreamCreationError);

    // A non-SETTINGS first frame is H3_MISSING_SETTINGS.
    var bad_control = ControlStream{};
    try bad_control.open_stream();
    expect(&failures, "non-SETTINGS first frame -> H3_MISSING_SETTINGS", bad_control.onFrame(.goaway) == error.MissingSettings);

    std.debug.print("RFC 9114 7.2: frame-per-stream permission matrix\n", .{});

    expect(&failures, "SETTINGS on control, not request", frameAllowedOnControl(.settings) and !frameAllowedOnRequest(.settings));
    expect(&failures, "HEADERS on request, not control", frameAllowedOnRequest(.headers) and !frameAllowedOnControl(.headers));
    expect(&failures, "DATA on request, not control", frameAllowedOnRequest(.data) and !frameAllowedOnControl(.data));
    expect(&failures, "GOAWAY on control, not request", frameAllowedOnControl(.goaway) and !frameAllowedOnRequest(.goaway));
    expect(&failures, "MAX_PUSH_ID on control, not request", frameAllowedOnControl(.max_push_id) and !frameAllowedOnRequest(.max_push_id));

    std.debug.print("RFC 9114 4.1: request frame sequence\n", .{});

    // HEADERS then DATA is the normal request shape.
    const after_headers = requestFrameTransition(.initial, .headers);
    expect(&failures, "HEADERS opens the message", after_headers != null and after_headers.? == .header_seen);
    expect(&failures, "DATA after HEADERS ok", requestFrameTransition(.header_seen, .data) != null);

    // A trailing HEADERS is allowed; anything after it is not.
    const trailer = requestFrameTransition(.header_seen, .headers);
    expect(&failures, "trailing HEADERS ok", trailer != null and trailer.? == .trailer_seen);
    expect(&failures, "frame after trailer -> H3_FRAME_UNEXPECTED", requestFrameTransition(.trailer_seen, .data) == null);

    // DATA before any HEADERS is invalid.
    expect(&failures, "DATA before HEADERS -> H3_FRAME_UNEXPECTED", requestFrameTransition(.initial, .data) == null);

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("PASS: all RFC 9114 H1 stream + frame checks hold\n", .{});
    } else {
        std.debug.print("FAIL: {d} check(s) failed\n", .{failures});
        std.process.exit(1);
    }
}
