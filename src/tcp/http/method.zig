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

    // --------------------------------------------------------- //

    /// Brief:
    /// Get self object string from enum
    ///
    /// Note:
    /// - exhaustive
    ///
    /// Param:
    /// self - zix.Tcp.Method.Code
    ///
    /// Return:
    /// []const u8
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
        };
    }
    /// Brief:
    /// Get self object as a string
    ///
    /// Return:
    /// []const u8
    pub fn asString(self: Self) []const u8 {
        return Self.toString(self);
    }
};

// --------------------------------------------------------- //

/// Brief:
/// Get enum from string
///
/// Note:
/// - If not match, it will return GET
///
/// Params:
/// method_string - []const u8 (insensitive; forced to lowercase)
///
/// Return:
/// zix.Tcp.Http.Method.Code
pub fn enumFromString(method_string: []const u8) Code {
    var data: [8]u8 = undefined;
    const mod = std.ascii.lowerString(&data, method_string);

    if (std.mem.eql(u8, mod, "get")) { return Code.GET; }
    if (std.mem.eql(u8, mod, "head")) { return Code.HEAD; }
    if (std.mem.eql(u8, mod, "post")) { return Code.POST; }
    if (std.mem.eql(u8, mod, "put")) { return Code.PUT; }
    if (std.mem.eql(u8, mod, "delete")) { return Code.DELETE; }
    if (std.mem.eql(u8, mod, "patch")) { return Code.PATCH; }
    if (std.mem.eql(u8, mod, "options")) { return Code.OPTIONS; }
    if (std.mem.eql(u8, mod, "trace")) { return Code.TRACE; }
    if (std.mem.eql(u8, mod, "connect")) { return Code.CONNECT; }

    return Code.GET;
}

/// Brief:
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
/// []const u8
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
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix test: tcp http method fn/s" {
    const es = [_]Code {
        Code.GET,
        Code.HEAD,
        Code.POST,
        Code.PUT,
        Code.DELETE,
        Code.PATCH,
        Code.OPTIONS,
        Code.TRACE,
        Code.CONNECT,
    };

    for (es) |e| {
        const e_str = stringFromEnum(e);

        try std.testing.expect(
            std.mem.eql(
                u8, e_str, e.asString()));

        const expected1 = enumFromString(e_str);
        try std.testing.expect(
            expected1 == e);

        const expected2 = stringFromEnum(e);
        try std.testing.expect(
            std.mem.eql(
                u8, e_str, expected2));
    }
}

