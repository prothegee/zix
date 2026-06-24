//! HTTP/3 PoC, phase H2 (http3-plan.md): RFC 9114 section 4.1.2 (malformed messages), 4.2 (HTTP
//! fields) and 4.3 (pseudo-header fields).
//!
//! Note:
//! - H1 framed the streams. H2 validates the message a HEADERS frame carries. HTTP/3 is deliberately
//!   strict here: field names MUST be lowercase, the mandatory pseudo-headers MUST be present and
//!   the prohibited ones absent, pseudo-headers MUST precede regular fields, and a Content-Length
//!   MUST equal the sum of the DATA frame lengths. Any violation is malformed.
//! - The oracle is the RFC text: 4.3.1 fixes the request pseudo-headers (:method, :scheme, :path,
//!   and :authority unless CONNECT), 4.3.2 fixes the response pseudo-header (:status), and 4.1.2
//!   enumerates the malformed conditions. A malformed message is a stream error of type
//!   H3_MESSAGE_ERROR. Header lists are validated in process.
//! - This is message-level validation, the layer above QPACK decode: by here the field list is
//!   already decompressed.
//!
//! Run:    zig run rnd/0.5.x/http3_h2_poc.zig
//! Verify: bash rnd/0.5.x/verify-http3-h2.sh

const std = @import("std");

// --------------------------------------------------------------- //

/// A decompressed field line.
const Field = struct { name: []const u8, value: []const u8 };

/// Whether the message is a request or a response (RFC 9114 4.3).
const MessageKind = enum { request, response };

/// The message-validation error (RFC 9114 4.1.2): a malformed message is H3_MESSAGE_ERROR.
const MessageError = error{MessageError};

/// Whether a field name is connection-specific and therefore prohibited in HTTP/3 (RFC 9114 4.2).
fn connectionSpecific(name: []const u8) bool {
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
/// kind - request or response
/// fields - the decompressed field list, in order
/// content_length - the Content-Length value if the message declared one
/// data_total - the summed length of the DATA frames received
fn validateMessage(kind: MessageKind, fields: []const Field, content_length: ?u64, data_total: u64) MessageError!void {
    var seen_regular = false;
    var method: ?[]const u8 = null;
    var has_scheme = false;
    var has_path = false;
    var has_authority = false;
    var has_status = false;

    for (fields) |field| {
        // Field names MUST be lowercase (4.2): any uppercase is malformed.
        for (field.name) |c| {
            if (c >= 'A' and c <= 'Z') return error.MessageError;
        }

        if (field.name.len > 0 and field.name[0] == ':') {
            // Pseudo-headers MUST precede regular fields (4.1.2).
            if (seen_regular) return error.MessageError;

            if (std.mem.eql(u8, field.name, ":method")) {
                method = field.value;
            } else if (std.mem.eql(u8, field.name, ":scheme")) {
                has_scheme = true;
            } else if (std.mem.eql(u8, field.name, ":path")) {
                has_path = true;
            } else if (std.mem.eql(u8, field.name, ":authority")) {
                has_authority = true;
            } else if (std.mem.eql(u8, field.name, ":status")) {
                has_status = true;
            } else {
                // An unrecognized pseudo-header is prohibited (4.1.2).
                return error.MessageError;
            }
        } else {
            seen_regular = true;
            if (connectionSpecific(field.name)) return error.MessageError;
        }
    }

    switch (kind) {
        .request => {
            // Response pseudo-headers are prohibited in a request.
            if (has_status) return error.MessageError;

            if (method) |verb| {
                if (std.mem.eql(u8, verb, "CONNECT")) {
                    // CONNECT: :authority present, :scheme and :path omitted (4.4).
                    if (!has_authority or has_scheme or has_path) return error.MessageError;
                } else {
                    // Every other request MUST carry :method, :scheme, :path (4.3.1).
                    if (!has_scheme or !has_path) return error.MessageError;
                }
            } else {
                return error.MessageError;
            }
        },
        .response => {
            // A response MUST carry :status and no request pseudo-headers (4.3.2).
            if (!has_status) return error.MessageError;
            if (method != null or has_scheme or has_path or has_authority) return error.MessageError;
        },
    }

    // Content-Length, when present, MUST equal the sum of DATA frame lengths (4.1.2).
    if (content_length) |declared| {
        if (declared != data_total) return error.MessageError;
    }
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

/// Whether validating the message raised H3_MESSAGE_ERROR.
fn isMalformed(kind: MessageKind, fields: []const Field, content_length: ?u64, data_total: u64) bool {
    return std.meta.isError(validateMessage(kind, fields, content_length, data_total));
}

pub fn main() !void {
    var failures: usize = 0;

    std.debug.print("RFC 9114 4.3: well-formed messages\n", .{});

    const request = [_]Field{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "user-agent", .value = "zix" },
    };
    expect(&failures, "valid request is well-formed", !isMalformed(.request, &request, null, 0));

    const connect = [_]Field{
        .{ .name = ":method", .value = "CONNECT" },
        .{ .name = ":authority", .value = "example.com:443" },
    };
    expect(&failures, "valid CONNECT request is well-formed", !isMalformed(.request, &connect, null, 0));

    const response = [_]Field{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-type", .value = "text/plain" },
    };
    expect(&failures, "valid response is well-formed", !isMalformed(.response, &response, null, 0));

    std.debug.print("RFC 9114 4.3: mandatory pseudo-headers\n", .{});

    const no_method = [_]Field{ .{ .name = ":scheme", .value = "https" }, .{ .name = ":path", .value = "/" } };
    expect(&failures, "request missing :method -> H3_MESSAGE_ERROR", isMalformed(.request, &no_method, null, 0));

    const no_path = [_]Field{ .{ .name = ":method", .value = "GET" }, .{ .name = ":scheme", .value = "https" } };
    expect(&failures, "request missing :path -> H3_MESSAGE_ERROR", isMalformed(.request, &no_path, null, 0));

    const no_status = [_]Field{.{ .name = "content-type", .value = "text/plain" }};
    expect(&failures, "response missing :status -> H3_MESSAGE_ERROR", isMalformed(.response, &no_status, null, 0));

    const connect_with_path = [_]Field{
        .{ .name = ":method", .value = "CONNECT" },
        .{ .name = ":authority", .value = "example.com:443" },
        .{ .name = ":path", .value = "/" },
    };
    expect(&failures, "CONNECT with :path -> H3_MESSAGE_ERROR", isMalformed(.request, &connect_with_path, null, 0));

    std.debug.print("RFC 9114 4.1.2 / 4.2: prohibited fields + ordering + case\n", .{});

    const uppercase = [_]Field{
        .{ .name = ":method", .value = "GET" }, .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },     .{ .name = "User-Agent", .value = "zix" },
    };
    expect(&failures, "uppercase field name -> H3_MESSAGE_ERROR", isMalformed(.request, &uppercase, null, 0));

    const pseudo_after = [_]Field{
        .{ .name = ":method", .value = "GET" },   .{ .name = "user-agent", .value = "zix" },
        .{ .name = ":scheme", .value = "https" }, .{ .name = ":path", .value = "/" },
    };
    expect(&failures, "pseudo-header after regular field -> H3_MESSAGE_ERROR", isMalformed(.request, &pseudo_after, null, 0));

    const unknown_pseudo = [_]Field{
        .{ .name = ":method", .value = "GET" }, .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },     .{ .name = ":protocol", .value = "x" },
    };
    expect(&failures, "unknown pseudo-header -> H3_MESSAGE_ERROR", isMalformed(.request, &unknown_pseudo, null, 0));

    const status_in_request = [_]Field{
        .{ .name = ":method", .value = "GET" }, .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },     .{ .name = ":status", .value = "200" },
    };
    expect(&failures, "response pseudo (:status) in request -> H3_MESSAGE_ERROR", isMalformed(.request, &status_in_request, null, 0));

    const method_in_response = [_]Field{ .{ .name = ":status", .value = "200" }, .{ .name = ":method", .value = "GET" } };
    expect(&failures, "request pseudo (:method) in response -> H3_MESSAGE_ERROR", isMalformed(.response, &method_in_response, null, 0));

    const conn_specific = [_]Field{
        .{ .name = ":status", .value = "200" },
        .{ .name = "connection", .value = "keep-alive" },
    };
    expect(&failures, "connection-specific field -> H3_MESSAGE_ERROR", isMalformed(.response, &conn_specific, null, 0));

    std.debug.print("RFC 9114 4.1.2: Content-Length vs DATA length\n", .{});

    // A response declaring Content-Length 5 with 5 bytes of DATA is well-formed.
    expect(&failures, "Content-Length matches DATA sum ok", !isMalformed(.response, &response, 5, 5));
    expect(&failures, "Content-Length != DATA sum -> H3_MESSAGE_ERROR", isMalformed(.response, &response, 5, 3));

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("PASS: all RFC 9114 H2 message validation checks hold\n", .{});
    } else {
        std.debug.print("FAIL: {d} check(s) failed\n", .{failures});
        std.process.exit(1);
    }
}
