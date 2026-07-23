//! zix HTTP/3 application framing and semantics (RFC 9114, Layer H).
//!
//! What:
//! - The stream and frame structure (6.2 / 7.2): the control stream type, the SETTINGS-first rule,
//!   the frame-per-stream permission matrix, and the legal frame order within a request.
//! - Message validation (4.1.2 / 4.2 / 4.3): lowercase field names, mandatory and prohibited
//!   pseudo-headers, pseudo-before-regular ordering, and Content-Length vs the DATA sum.
//! - Connection lifecycle and the error vocabulary (5.2 / 7.2.7 / 8.1): GOAWAY monotonicity,
//!   MAX_PUSH_ID / PUSH_PROMISE direction, and the seventeen error codes plus the grease range.
//! - Pure framing and validation logic, no crypto. Proven against the RFC rules in the tests below.
//!
//! Note:
//! - Implemented and unit-tested, but not wired into the serve path yet (deferred). The live request
//!   path handles the minimal HTTP/3 framing inline in dispatch/common.zig. Wiring the control
//!   stream, GOAWAY, and message validation is v2 work.

const std = @import("std");

/// The HTTP/3 frame types (RFC 9114 7.2). The values are sparse: 0x02 and 0x06 are reserved or used
/// elsewhere, so the set is explicit.
pub const FrameType = enum(u64) {
    data = 0x00,
    headers = 0x01,
    cancel_push = 0x03,
    settings = 0x04,
    push_promise = 0x05,
    goaway = 0x07,
    max_push_id = 0x0d,
};

/// The HTTP/3 unidirectional stream types (RFC 9114 6.2, QPACK 4.2).
pub const control_stream: u64 = 0x00;
pub const push_stream: u64 = 0x01;
pub const qpack_encoder_stream: u64 = 0x02;
pub const qpack_decoder_stream: u64 = 0x03;

/// Whether a frame type may appear on the control stream (RFC 9114 7.2). DATA / HEADERS /
/// PUSH_PROMISE on the control stream are H3_FRAME_UNEXPECTED.
pub fn frameAllowedOnControl(frame: FrameType) bool {
    return switch (frame) {
        .settings, .goaway, .max_push_id, .cancel_push => true,
        .data, .headers, .push_promise => false,
    };
}

/// Whether a frame type may appear on a request stream (RFC 9114 7.2). SETTINGS / GOAWAY /
/// MAX_PUSH_ID / CANCEL_PUSH on a request stream are H3_FRAME_UNEXPECTED.
pub fn frameAllowedOnRequest(frame: FrameType) bool {
    return switch (frame) {
        .headers, .data, .push_promise => true,
        .settings, .goaway, .max_push_id, .cancel_push => false,
    };
}

// --------------------------------------------------------------- //

/// The control-stream errors (RFC 9114 6.2.1).
pub const ControlError = error{
    /// The first frame on the control stream was not SETTINGS: H3_MISSING_SETTINGS.
    MissingSettings,
    /// A second control stream was opened: H3_STREAM_CREATION_ERROR.
    StreamCreationError,
};

/// Tracks the control-stream invariants (RFC 9114 6.2.1): exactly one control stream, SETTINGS first.
pub const ControlStream = struct {
    open: bool = false,
    settings_seen: bool = false,

    /// Open the single control stream. A second one is H3_STREAM_CREATION_ERROR.
    pub fn openStream(self: *ControlStream) ControlError!void {
        if (self.open) return error.StreamCreationError;
        self.open = true;
    }

    /// Process a frame on the control stream. The first frame MUST be SETTINGS.
    pub fn onFrame(self: *ControlStream, frame: FrameType) ControlError!void {
        if (!self.settings_seen and frame != .settings) return error.MissingSettings;
        self.settings_seen = true;
    }
};

/// The position within a request's frame sequence (RFC 9114 4.1): a HEADERS, then optional DATA, then
/// an optional trailing HEADERS, and nothing after.
pub const RequestState = enum { initial, header_seen, trailer_seen };

/// Advance the request frame sequence (RFC 9114 4.1). A null result is an invalid sequence,
/// H3_FRAME_UNEXPECTED: DATA before HEADERS, or any frame after the trailing HEADERS.
pub fn requestFrameTransition(state: RequestState, frame: FrameType) ?RequestState {
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

/// A decompressed field line (the output of QPACK decode).
pub const Field = struct { name: []const u8, value: []const u8 };

/// Whether the message is a request or a response (RFC 9114 4.3).
pub const MessageKind = enum { request, response };

/// The message-validation error (RFC 9114 4.1.2): a malformed message is H3_MESSAGE_ERROR.
pub const MessageError = error{MessageError};

/// Whether a field name is connection-specific and therefore prohibited in HTTP/3 (RFC 9114 4.2).
pub fn connectionSpecific(name: []const u8) bool {
    const prohibited = [_][]const u8{ "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade" };
    for (prohibited) |bad| {
        if (std.mem.eql(u8, name, bad)) return true;
    }

    return false;
}

/// Validate a decompressed HTTP/3 message (RFC 9114 4.1.2 / 4.2 / 4.3). Returns H3_MESSAGE_ERROR on
/// any malformed condition.
///
/// Param:
/// kind - MessageKind (request or response)
/// fields - []const Field (the decompressed field list, in order)
/// content_length - ?u64 (the Content-Length value if the message declared one)
/// data_total - u64 (the summed length of the DATA frames received)
///
/// Return:
/// - void
/// - error.MessageError on any malformed condition
pub fn validateMessage(kind: MessageKind, fields: []const Field, content_length: ?u64, data_total: u64) MessageError!void {
    var seen_regular = false;
    var method: ?[]const u8 = null;
    var has_scheme = false;
    var has_path = false;
    var has_authority = false;
    var has_status = false;

    for (fields) |entry| {
        for (entry.name) |c| {
            if (c >= 'A' and c <= 'Z') return error.MessageError;
        }

        if (entry.name.len > 0 and entry.name[0] == ':') {
            if (seen_regular) return error.MessageError;

            if (std.mem.eql(u8, entry.name, ":method")) {
                method = entry.value;
            } else if (std.mem.eql(u8, entry.name, ":scheme")) {
                has_scheme = true;
            } else if (std.mem.eql(u8, entry.name, ":path")) {
                has_path = true;
            } else if (std.mem.eql(u8, entry.name, ":authority")) {
                has_authority = true;
            } else if (std.mem.eql(u8, entry.name, ":status")) {
                has_status = true;
            } else {
                return error.MessageError;
            }
        } else {
            seen_regular = true;
            if (connectionSpecific(entry.name)) return error.MessageError;
        }
    }

    switch (kind) {
        .request => {
            if (has_status) return error.MessageError;

            if (method) |verb| {
                if (std.mem.eql(u8, verb, "CONNECT")) {
                    if (!has_authority or has_scheme or has_path) return error.MessageError;
                } else {
                    if (!has_scheme or !has_path) return error.MessageError;
                }
            } else {
                return error.MessageError;
            }
        },
        .response => {
            if (!has_status) return error.MessageError;
            if (method != null or has_scheme or has_path or has_authority) return error.MessageError;
        },
    }

    if (content_length) |declared| {
        if (declared != data_total) return error.MessageError;
    }
}

/// Whether validating the message raised H3_MESSAGE_ERROR.
pub fn isMalformed(kind: MessageKind, fields: []const Field, content_length: ?u64, data_total: u64) bool {
    return std.meta.isError(validateMessage(kind, fields, content_length, data_total));
}

// --------------------------------------------------------------- //

/// Which side of the connection an endpoint is (RFC 9114 7.2.7).
pub const Role = enum { client, server };

/// Whether a frame type may be SENT by the given role (RFC 9114 7.2.5 / 7.2.7). MAX_PUSH_ID is
/// client-only and PUSH_PROMISE is server-only, a frame from the wrong side is H3_FRAME_UNEXPECTED
/// at the receiver.
pub fn frameSendableBy(frame: FrameType, sender: Role) bool {
    return switch (frame) {
        .max_push_id => sender == .client,
        .push_promise => sender == .server,
        else => true,
    };
}

/// The identifier-ordering error (RFC 9114 5.2 / 7.2.7): H3_ID_ERROR.
pub const IdError = error{IdError};

/// Tracks received GOAWAY identifiers (RFC 9114 5.2): each MUST NOT exceed any previous one. A larger
/// identifier is H3_ID_ERROR.
pub const GoawayTracker = struct {
    last: ?u64 = null,

    pub fn receive(self: *GoawayTracker, id: u64) IdError!void {
        if (self.last) |prev| {
            if (id > prev) return error.IdError;
        }
        self.last = id;
    }
};

/// Tracks the push limit set by MAX_PUSH_ID (RFC 9114 7.2.7): the value only increases. A smaller
/// value is H3_ID_ERROR.
pub const MaxPushIdTracker = struct {
    current: ?u64 = null,

    pub fn update(self: *MaxPushIdTracker, id: u64) IdError!void {
        if (self.current) |prev| {
            if (id < prev) return error.IdError;
        }
        self.current = id;
    }
};

/// The HTTP/3 error codes (RFC 9114 8.1).
pub const Http3Error = enum(u64) {
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
pub fn isReservedErrorCode(code: u64) bool {
    if (code < 0x21) return false;

    return (code - 0x21) % 0x1f == 0;
}

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

test "zix http3: RFC 9114 7.2 / 6.2 frame and stream type values" {
    try std.testing.expectEqual(@as(u64, 0x00), @intFromEnum(FrameType.data));
    try std.testing.expectEqual(@as(u64, 0x01), @intFromEnum(FrameType.headers));
    try std.testing.expectEqual(@as(u64, 0x04), @intFromEnum(FrameType.settings));
    try std.testing.expectEqual(@as(u64, 0x07), @intFromEnum(FrameType.goaway));
    try std.testing.expectEqual(@as(u64, 0x0d), @intFromEnum(FrameType.max_push_id));

    try std.testing.expect(control_stream == 0x00 and push_stream == 0x01);
    try std.testing.expect(qpack_encoder_stream == 0x02 and qpack_decoder_stream == 0x03);
}

test "zix http3: RFC 9114 6.2.1 control stream and SETTINGS first" {
    var control = ControlStream{};
    try control.openStream();
    try control.onFrame(.settings);
    try control.onFrame(.goaway);
    try std.testing.expectError(error.StreamCreationError, control.openStream());

    var bad_control = ControlStream{};
    try bad_control.openStream();
    try std.testing.expectError(error.MissingSettings, bad_control.onFrame(.goaway));
}

test "zix http3: RFC 9114 7.2 frame-per-stream matrix and 4.1 request sequence" {
    try std.testing.expect(frameAllowedOnControl(.settings) and !frameAllowedOnRequest(.settings));
    try std.testing.expect(frameAllowedOnRequest(.headers) and !frameAllowedOnControl(.headers));
    try std.testing.expect(frameAllowedOnControl(.goaway) and !frameAllowedOnRequest(.goaway));

    try std.testing.expectEqual(RequestState.header_seen, requestFrameTransition(.initial, .headers).?);
    try std.testing.expect(requestFrameTransition(.header_seen, .data) != null);
    try std.testing.expectEqual(RequestState.trailer_seen, requestFrameTransition(.header_seen, .headers).?);
    try std.testing.expect(requestFrameTransition(.trailer_seen, .data) == null);
    try std.testing.expect(requestFrameTransition(.initial, .data) == null);
}

test "zix http3: RFC 9114 4.3 message validation" {
    const request = [_]Field{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "user-agent", .value = "zix" },
    };
    try std.testing.expect(!isMalformed(.request, &request, null, 0));

    const connect = [_]Field{ .{ .name = ":method", .value = "CONNECT" }, .{ .name = ":authority", .value = "example.com:443" } };
    try std.testing.expect(!isMalformed(.request, &connect, null, 0));

    const response = [_]Field{ .{ .name = ":status", .value = "200" }, .{ .name = "content-type", .value = "text/plain" } };
    try std.testing.expect(!isMalformed(.response, &response, null, 0));

    const no_method = [_]Field{ .{ .name = ":scheme", .value = "https" }, .{ .name = ":path", .value = "/" } };
    try std.testing.expect(isMalformed(.request, &no_method, null, 0));

    const uppercase = [_]Field{ .{ .name = ":method", .value = "GET" }, .{ .name = ":scheme", .value = "https" }, .{ .name = ":path", .value = "/" }, .{ .name = "User-Agent", .value = "zix" } };
    try std.testing.expect(isMalformed(.request, &uppercase, null, 0));

    const pseudo_after = [_]Field{ .{ .name = ":method", .value = "GET" }, .{ .name = "user-agent", .value = "zix" }, .{ .name = ":scheme", .value = "https" }, .{ .name = ":path", .value = "/" } };
    try std.testing.expect(isMalformed(.request, &pseudo_after, null, 0));

    const conn_specific = [_]Field{ .{ .name = ":status", .value = "200" }, .{ .name = "connection", .value = "keep-alive" } };
    try std.testing.expect(isMalformed(.response, &conn_specific, null, 0));

    try std.testing.expect(!isMalformed(.response, &response, 5, 5));
    try std.testing.expect(isMalformed(.response, &response, 5, 3));
}

test "zix http3: RFC 9114 5.2 / 7.2.7 GOAWAY, direction, and 8.1 error codes" {
    var goaway = GoawayTracker{};
    try goaway.receive(100);
    try goaway.receive(60);
    try goaway.receive(60);
    try std.testing.expectError(error.IdError, goaway.receive(80));

    try std.testing.expect(frameSendableBy(.max_push_id, .client) and !frameSendableBy(.max_push_id, .server));
    try std.testing.expect(frameSendableBy(.push_promise, .server) and !frameSendableBy(.push_promise, .client));

    var max_push = MaxPushIdTracker{};
    try max_push.update(10);
    try max_push.update(20);
    try std.testing.expectError(error.IdError, max_push.update(5));

    try std.testing.expectEqual(@as(u64, 0x0100), @intFromEnum(Http3Error.no_error));
    try std.testing.expectEqual(@as(u64, 0x0105), @intFromEnum(Http3Error.frame_unexpected));
    try std.testing.expectEqual(@as(u64, 0x0110), @intFromEnum(Http3Error.version_fallback));

    try std.testing.expect(isReservedErrorCode(0x21));
    try std.testing.expect(isReservedErrorCode(0x40));
    try std.testing.expect(!isReservedErrorCode(0x0105));
}
