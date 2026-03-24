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

    /// brief:
    /// get string from method code enum
    ///
    /// note:
    /// - exhaustive
    ///
    /// param:
    /// self - zix.Tcp.Method.Code
    ///
    /// return:
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
    /// brief:
    /// get self object as string
    ///
    /// return:
    /// []const u8
    pub fn asString(self: Self) []const u8 {
        return Self.toString(self);
    }
};

// --------------------------------------------------------- //

/// Brief:
/// Get enum method code from string
///
/// Note:
/// By default it will return "GET"
///
/// Return:
/// zix.Http.Method.Code
pub fn enumFromString(method_string: []const u8) Code {
    if (std.mem.eql(u8, method_string, "GET")) { return Code.GET; }
    if (std.mem.eql(u8, method_string, "HEAD")) { return Code.HEAD; }
    if (std.mem.eql(u8, method_string, "POST")) { return Code.POST; }
    if (std.mem.eql(u8, method_string, "PUT")) { return Code.PUT; }
    if (std.mem.eql(u8, method_string, "DELETE")) { return Code.DELETE; }
    if (std.mem.eql(u8, method_string, "PATCH")) { return Code.PATCH; }
    if (std.mem.eql(u8, method_string, "OPTIONS")) { return Code.OPTIONS; }
    if (std.mem.eql(u8, method_string, "TRACE")) { return Code.TRACE; }
    if (std.mem.eql(u8, method_string, "CONNECT")) { return Code.CONNECT; }
    return Code.GET;
}

/// brief:
/// get string from method code enum
///
/// note:
/// - exhaustive
/// - seperated by it's enum
///
/// param:
/// self - zix.Tcp.Method.Code
///
/// return:
/// []const u8
fn stringFromEnum(method_enum: Code) []const u8 {
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

test "zix test: http method fn/s" {
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
        const e_str = codeStringFromEnum(e);

        try std.testing.expect(
            std.mem.eql(
                u8, e_str, e.asString()));

        const expected1 = codeFromString(e_str);
        try std.testing.expect(
            expected1 == e);

        const expected2 = codeStringFromEnum(e);
        try std.testing.expect(
            std.mem.eql(
                u8, e_str, expected2));
    }
}

