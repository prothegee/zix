//! zix http method

const std = @import("std");

/// zix http method code
pub const Code = enum(u8) {
    const Self = @This();

    // --------------------------------------------------------- //

    GET,
    HEAD,
    POST,
    PUT,
    DELETE,
    PATCH,
    OPTIONS,
    TRACE,
    CONNECT,
    /// RFC 10008. Safe and idempotent like GET, carries content like POST.
    QUERY,

    // --------------------------------------------------------- //

    /// Get self object string from enum
    ///
    /// Note:
    /// - exhaustive
    ///
    /// Param:
    /// self - zix.Tcp.Method.Code
    ///
    /// Return:
    /// - []const u8
    fn toString(self: Code) []const u8 {
        return switch (self) {
            .GET => "GET",
            .HEAD => "HEAD",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .PATCH => "PATCH",
            .OPTIONS => "OPTIONS",
            .TRACE => "TRACE",
            .CONNECT => "CONNECT",
            .QUERY => "QUERY",
        };
    }
    /// Get self object as a string
    ///
    /// Return:
    /// - []const u8
    pub fn asString(self: Self) []const u8 {
        return Self.toString(self);
    }
};

// --------------------------------------------------------- //

/// Longest method token this engine knows, in bytes ("OPTIONS", "CONNECT").
/// A token longer than this names no known method, so it never needs lowering.
pub const MAX_TOKEN_LEN: usize = 7;

/// Get enum from string, reporting no match
///
/// Note:
/// - Returns null when the token names no method this engine knows, which lets
///   a caller answer 501 Not Implemented instead of acting on a wrong method
/// - A token longer than MAX_TOKEN_LEN is rejected before any copy, so an
///   oversized token from the wire cannot overrun the lowercase buffer
///
/// Param:
/// method_string - []const u8 (insensitive, forced to lowercase)
///
/// Return:
/// - zix.Tcp.Http.Method.Code
/// - null when the token matches no known method
pub fn codeFromString(method_string: []const u8) ?Code {
    if (method_string.len > MAX_TOKEN_LEN) return null;

    var data: [MAX_TOKEN_LEN]u8 = undefined;
    const mod = std.ascii.lowerString(&data, method_string);

    if (std.mem.eql(u8, mod, "get")) {
        return Code.GET;
    }
    if (std.mem.eql(u8, mod, "head")) {
        return Code.HEAD;
    }
    if (std.mem.eql(u8, mod, "post")) {
        return Code.POST;
    }
    if (std.mem.eql(u8, mod, "put")) {
        return Code.PUT;
    }
    if (std.mem.eql(u8, mod, "delete")) {
        return Code.DELETE;
    }
    if (std.mem.eql(u8, mod, "patch")) {
        return Code.PATCH;
    }
    if (std.mem.eql(u8, mod, "options")) {
        return Code.OPTIONS;
    }
    if (std.mem.eql(u8, mod, "trace")) {
        return Code.TRACE;
    }
    if (std.mem.eql(u8, mod, "connect")) {
        return Code.CONNECT;
    }
    if (std.mem.eql(u8, mod, "query")) {
        return Code.QUERY;
    }

    return null;
}

/// Get enum from string
///
/// Note:
/// - If not match, it will return GET
/// - Callers that must tell an unknown method apart from a real GET use
///   codeFromString instead, which reports the no-match case as null
///
/// Param:
/// method_string - []const u8 (insensitive, forced to lowercase)
///
/// Return:
/// - zix.Tcp.Http.Method.Code
pub fn enumFromString(method_string: []const u8) Code {
    return codeFromString(method_string) orelse Code.GET;
}

/// Get string from enum
///
/// Note:
/// - Exhaustive
/// - Seperated by it's enum
///
/// Param:
/// method_enum - zix.Tcp.Http.Method.Code
///
/// Return:
/// - []const u8
pub fn stringFromEnum(method_enum: Code) []const u8 {
    return switch (method_enum) {
        .GET => "GET",
        .HEAD => "HEAD",
        .POST => "POST",
        .PUT => "PUT",
        .DELETE => "DELETE",
        .PATCH => "PATCH",
        .OPTIONS => "OPTIONS",
        .TRACE => "TRACE",
        .CONNECT => "CONNECT",
        .QUERY => "QUERY",
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix http: tcp http method" {
    const all_codes = [_]Code{
        Code.GET,
        Code.HEAD,
        Code.POST,
        Code.PUT,
        Code.DELETE,
        Code.PATCH,
        Code.OPTIONS,
        Code.TRACE,
        Code.CONNECT,
        Code.QUERY,
    };

    for (all_codes) |e| {
        const e_str = stringFromEnum(e);

        try std.testing.expect(std.mem.eql(u8, e_str, e.asString()));

        const expected1 = enumFromString(e_str);
        try std.testing.expect(expected1 == e);

        const expected2 = stringFromEnum(e);
        try std.testing.expect(std.mem.eql(u8, e_str, expected2));
    }
}

test "zix http: method QUERY resolves from its wire token" {
    try std.testing.expectEqual(Code.QUERY, enumFromString("QUERY"));
    try std.testing.expectEqual(Code.QUERY, codeFromString("QUERY").?);
}

test "zix http: method QUERY is not reported as GET" {
    // The pre-RFC-10008 behaviour answered GET for every unknown token, which
    // made a QUERY request indistinguishable from a GET to every handler.
    try std.testing.expect(enumFromString("QUERY") != Code.GET);
}

test "zix http: method QUERY token matching is case-insensitive" {
    try std.testing.expectEqual(Code.QUERY, enumFromString("query"));
    try std.testing.expectEqual(Code.QUERY, enumFromString("QuErY"));
}

test "zix http: method codeFromString reports an unknown token as null" {
    try std.testing.expect(codeFromString("BREW") == null);
    try std.testing.expect(codeFromString("") == null);
}

test "zix http: method codeFromString rejects a token past MAX_TOKEN_LEN" {
    // Longer than any known method, so it is refused before the lowercase copy.
    // Without the length guard this overruns the stack buffer.
    try std.testing.expect(codeFromString("PROPPATCH") == null);
    try std.testing.expect(codeFromString("QUERYQUERYQUERY") == null);
}

test "zix http: method enumFromString keeps its GET fallback for unknown tokens" {
    try std.testing.expectEqual(Code.GET, enumFromString("BREW"));
    try std.testing.expectEqual(Code.GET, enumFromString("PROPPATCH"));
}
