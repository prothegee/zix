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

    pub fn asString(self: Self) []const u8 {
        return Self.toString(self);
    }

    /// brief:
    /// get enum method code from string
    ///
    /// note:
    /// by default it will return "GET"
    ///
    /// return:
    /// zix.Http.Method.Code
    pub fn fromString(self: []const u8) Code {
        if (std.mem.eql(u8, self, "GET")) { return Code.GET; }
        if (std.mem.eql(u8, self, "HEAD")) { return Code.HEAD; }
        if (std.mem.eql(u8, self, "POST")) { return Code.POST; }
        if (std.mem.eql(u8, self, "PUT")) { return Code.PUT; }
        if (std.mem.eql(u8, self, "DELETE")) { return Code.DELETE; }
        if (std.mem.eql(u8, self, "PATCH")) { return Code.PATCH; }
        if (std.mem.eql(u8, self, "OPTIONS")) { return Code.OPTIONS; }
        if (std.mem.eql(u8, self, "TRACE")) { return Code.TRACE; }
        if (std.mem.eql(u8, self, "CONNECT")) { return Code.CONNECT; }
        return "GET";
    }

    /// brief:
    /// get string from method code
    ///
    /// note:
    /// exhaustive
    ///
    /// param:
    /// self - zix.Tcp.Method.Code
    ///
    /// return:
    /// []const u8
    pub fn toString(self: Code) []const u8 {
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
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix test: http method fn asString" {
    const m = Code.GET;

    try std.testing.expect(
        std.mem.eql(
            u8, "GET", m.asString()));
}

