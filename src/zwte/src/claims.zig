//! zwte jwt registered claims (RFC 7519)

const std = @import("std");

// --------------------------------------------------------- //

/// Claim validation options. A null check is skipped.
pub const Options = struct {
    /// Expected issuer (`iss`).
    iss: ?[]const u8 = null,
    /// Expected subject (`sub`).
    sub: ?[]const u8 = null,
    /// Expected audience (`aud`).
    aud: ?[]const u8 = null,
    /// Expected token id (`jti`).
    jti: ?[]const u8 = null,
    /// Expected header type (`typ`).
    typ: ?[]const u8 = null,
    /// Current time in seconds since the Unix epoch.
    now_s: i64,
    /// Allowed clock skew in seconds.
    leeway_s: i64 = 0,
};

/// Claim validation errors.
pub const Error = error{
    InvalidIssuer,
    InvalidSubject,
    InvalidAudience,
    InvalidTokenId,
    InvalidType,
    Expired,
    NotYetValid,
    IssuedInFuture,
    MalformedClaim,
};

// --------------------------------------------------------- //

/// Validate the registered claims of a decoded payload and header.
///
/// Note:
/// - `payload` and `header` are decoded JSON objects.
/// - `exp`, `nbf`, and `iat` are checked only when present.
/// - Numeric dates are integer seconds, fractional values are rejected.
pub fn validate(payload: []const u8, header: []const u8, options: Options) Error!void {
    if (options.iss) |expected| {
        if (!stringEquals(payload, "iss", expected)) return error.InvalidIssuer;
    }

    if (options.sub) |expected| {
        if (!stringEquals(payload, "sub", expected)) return error.InvalidSubject;
    }

    if (options.aud) |expected| {
        if (!audienceMatches(payload, expected)) return error.InvalidAudience;
    }

    if (options.jti) |expected| {
        if (!stringEquals(payload, "jti", expected)) return error.InvalidTokenId;
    }

    if (options.typ) |expected| {
        if (!stringEquals(header, "typ", expected)) return error.InvalidType;
    }

    const leeway = options.leeway_s;

    switch (findInteger(payload, "exp")) {
        .absent => {},
        .malformed => return error.MalformedClaim,
        .value => |exp| {
            if (options.now_s >= exp + leeway) return error.Expired;
        },
    }

    switch (findInteger(payload, "nbf")) {
        .absent => {},
        .malformed => return error.MalformedClaim,
        .value => |nbf| {
            if (options.now_s < nbf - leeway) return error.NotYetValid;
        },
    }

    switch (findInteger(payload, "iat")) {
        .absent => {},
        .malformed => return error.MalformedClaim,
        .value => |iat| {
            if (iat > options.now_s + leeway) return error.IssuedInFuture;
        },
    }
}

// --------------------------------------------------------- //

const ValueKind = enum { string, number, object, array, literal };

const Field = struct {
    kind: ValueKind,
    value: []const u8,
};

const IntegerField = union(enum) {
    absent,
    value: i64,
    malformed,
};

/// Compare a string claim against `expected`.
fn stringEquals(json: []const u8, name: []const u8, expected: []const u8) bool {
    const field = findField(json, name) orelse return false;
    if (field.kind != .string) return false;

    return std.mem.eql(u8, field.value, expected);
}

/// Match `aud` as a single string or as an array of strings.
fn audienceMatches(payload: []const u8, expected: []const u8) bool {
    const field = findField(payload, "aud") orelse return false;

    if (field.kind == .string) {
        return std.mem.eql(u8, field.value, expected);
    }

    if (field.kind == .array) {
        return arrayContainsString(field.value, expected);
    }

    return false;
}

/// Whether a JSON string array contains `expected`.
fn arrayContainsString(array: []const u8, expected: []const u8) bool {
    var index = skipWhitespace(array, 0);
    if (index >= array.len or array[index] != '[') return false;
    index += 1;

    while (true) {
        index = skipWhitespace(array, index);
        if (index >= array.len or array[index] == ']') return false;
        if (array[index] != '"') return false;

        const value_start = index + 1;
        const value_end = skipString(array, index) orelse return false;

        if (std.mem.eql(u8, array[value_start .. value_end - 1], expected)) return true;

        index = skipWhitespace(array, value_end);
        if (index >= array.len) return false;
        if (array[index] == ',') {
            index += 1;
            continue;
        }
        if (array[index] == ']') return false;

        return false;
    }
}

/// Read an integer claim, distinguishing absent from malformed.
fn findInteger(json: []const u8, name: []const u8) IntegerField {
    const field = findField(json, name) orelse return .absent;
    if (field.kind != .number) return .malformed;

    const value = std.fmt.parseInt(i64, field.value, 10) catch return .malformed;

    return .{ .value = value };
}

/// Find a top-level field in a flat JSON object.
///
/// Note:
/// - Returns null when the field is absent or the object is malformed.
/// - String values are returned as raw content, JSON escapes are not decoded.
/// - Nested objects and arrays are skipped, so their keys never match.
fn findField(json: []const u8, name: []const u8) ?Field {
    var index = skipWhitespace(json, 0);
    if (index >= json.len or json[index] != '{') return null;
    index += 1;

    while (true) {
        index = skipWhitespace(json, index);
        if (index >= json.len) return null;
        if (json[index] == '}') return null;
        if (json[index] != '"') return null;

        const key_start = index + 1;
        const key_end = skipString(json, index) orelse return null;
        const key = json[key_start .. key_end - 1];

        index = skipWhitespace(json, key_end);
        if (index >= json.len or json[index] != ':') return null;
        index = skipWhitespace(json, index + 1);

        const kind = valueKind(json, index) orelse return null;
        const value_start = index;
        const value_end = skipValue(json, index) orelse return null;

        if (std.mem.eql(u8, key, name)) {
            const value = if (kind == .string)
                json[value_start + 1 .. value_end - 1]
            else
                json[value_start..value_end];

            return .{ .kind = kind, .value = value };
        }

        index = skipWhitespace(json, value_end);
        if (index >= json.len) return null;
        if (json[index] == ',') {
            index += 1;
            continue;
        }
        if (json[index] == '}') return null;

        return null;
    }
}

fn valueKind(json: []const u8, start: usize) ?ValueKind {
    if (start >= json.len) return null;

    return switch (json[start]) {
        '"' => .string,
        '{' => .object,
        '[' => .array,
        't', 'f', 'n' => .literal,
        '-', '0'...'9' => .number,
        else => null,
    };
}

/// Skip a JSON value, returning the index just past it.
fn skipValue(json: []const u8, start: usize) ?usize {
    if (start >= json.len) return null;

    return switch (json[start]) {
        '"' => skipString(json, start),
        '{', '[' => skipContainer(json, start),
        else => skipPrimitive(json, start),
    };
}

/// Skip a JSON string, returning the index just past the closing quote.
fn skipString(json: []const u8, start: usize) ?usize {
    var index = start + 1;

    while (index < json.len) {
        switch (json[index]) {
            '\\' => index += 2,
            '"' => return index + 1,
            else => index += 1,
        }
    }

    return null;
}

/// Skip a nested object or array by tracking bracket depth.
fn skipContainer(json: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var index = start;

    while (index < json.len) {
        switch (json[index]) {
            '"' => {
                index = skipString(json, index) orelse return null;
                continue;
            },
            '{', '[' => depth += 1,
            '}', ']' => {
                depth -= 1;
                if (depth == 0) return index + 1;
            },
            else => {},
        }

        index += 1;
    }

    return null;
}

/// Skip a number, literal, or bare token up to the next delimiter.
fn skipPrimitive(json: []const u8, start: usize) ?usize {
    var index = start;

    while (index < json.len) {
        switch (json[index]) {
            ',', '}', ']' => return index,
            else => {
                if (std.ascii.isWhitespace(json[index])) return index;
                index += 1;
            },
        }
    }

    return null;
}

fn skipWhitespace(json: []const u8, start: usize) usize {
    var index = start;

    while (index < json.len and std.ascii.isWhitespace(json[index])) index += 1;

    return index;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zwte claims: string claims" {
    const payload = "{\"iss\":\"https://issuer.example\",\"sub\":\"user-42\",\"jti\":\"token-7\"}";
    const header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";

    const options = Options{
        .iss = "https://issuer.example",
        .sub = "user-42",
        .jti = "token-7",
        .typ = "JWT",
        .now_s = 1_700_000_000,
    };

    try validate(payload, header, options);

    try std.testing.expectError(error.InvalidIssuer, validate(payload, header, .{ .iss = "other", .now_s = 0 }));
    try std.testing.expectError(error.InvalidSubject, validate(payload, header, .{ .sub = "other", .now_s = 0 }));
    try std.testing.expectError(error.InvalidTokenId, validate(payload, header, .{ .jti = "other", .now_s = 0 }));
    try std.testing.expectError(error.InvalidType, validate(payload, "{\"alg\":\"HS256\",\"typ\":\"JWS\"}", .{ .typ = "JWT", .now_s = 0 }));

    try std.testing.expectError(error.InvalidIssuer, validate("{}", header, .{ .iss = "x", .now_s = 0 }));
}

test "zwte claims: audience string and array" {
    const header = "{\"alg\":\"HS256\"}";

    try validate("{\"aud\":\"api.example\"}", header, .{ .aud = "api.example", .now_s = 0 });
    try validate("{\"aud\":[\"other\",\"api.example\"]}", header, .{ .aud = "api.example", .now_s = 0 });

    try std.testing.expectError(error.InvalidAudience, validate("{\"aud\":\"api.example\"}", header, .{ .aud = "missing", .now_s = 0 }));
    try std.testing.expectError(error.InvalidAudience, validate("{\"aud\":[\"other\",\"api.example\"]}", header, .{ .aud = "missing", .now_s = 0 }));
}

test "zwte claims: exp, nbf, iat" {
    const header = "{\"alg\":\"HS256\"}";
    const now_s: i64 = 1_700_000_000;

    try validate("{\"exp\":1700000100}", header, .{ .now_s = now_s });
    try std.testing.expectError(error.Expired, validate("{\"exp\":1699999999}", header, .{ .now_s = now_s }));
    try std.testing.expectError(error.Expired, validate("{\"exp\":1700000000}", header, .{ .now_s = now_s }));

    try validate("{\"nbf\":1699999999}", header, .{ .now_s = now_s });
    try std.testing.expectError(error.NotYetValid, validate("{\"nbf\":1700000001}", header, .{ .now_s = now_s }));

    try validate("{\"iat\":1699999999}", header, .{ .now_s = now_s });
    try std.testing.expectError(error.IssuedInFuture, validate("{\"iat\":1700000001}", header, .{ .now_s = now_s }));

    try validate("{\"exp\":1699999999}", header, .{ .now_s = now_s, .leeway_s = 2 });
    try validate("{\"nbf\":1700000001}", header, .{ .now_s = now_s, .leeway_s = 1 });
    try validate("{\"iat\":1700000001}", header, .{ .now_s = now_s, .leeway_s = 1 });
}

test "zwte claims: malformed numeric claim" {
    const header = "{\"alg\":\"HS256\"}";

    try std.testing.expectError(error.MalformedClaim, validate("{\"exp\":\"soon\"}", header, .{ .now_s = 0 }));
    try std.testing.expectError(error.MalformedClaim, validate("{\"exp\":1.5}", header, .{ .now_s = 0 }));
    try std.testing.expectError(error.MalformedClaim, validate("{\"nbf\":true}", header, .{ .now_s = 0 }));
}

test "zwte claims: nested values are skipped" {
    const header = "{\"alg\":\"HS256\"}";
    const payload = "{\"nested\":{\"iss\":\"evil\"},\"iss\":\"real\",\"list\":[{\"aud\":\"x\"}],\"aud\":\"real-aud\"}";

    try validate(payload, header, .{ .iss = "real", .aud = "real-aud", .now_s = 0 });
    try std.testing.expectError(error.InvalidIssuer, validate(payload, header, .{ .iss = "evil", .now_s = 0 }));
}

test "zwte claims: whitespace and missing optional claims" {
    const header = "{ \"alg\" : \"HS256\" , \"typ\" : \"JWT\" }";
    const payload = "{ \"iss\" : \"a\" , \"exp\" : 100 }";

    try validate(payload, header, .{ .iss = "a", .typ = "JWT", .now_s = 0 });
    try validate("{}", header, .{ .now_s = 0 });
}
