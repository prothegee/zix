//! Edge tests: zix.Http1 core parsing boundary conditions.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix edge: Http1 parseHead missing CRLF terminator returns IncompleteHeader" {
    try std.testing.expectError(
        error.IncompleteHeader,
        zix.Http1.parseHead("GET / HTTP/1.1\r\nHost: localhost"),
    );
}

test "zix edge: Http1 parseHead empty request line returns InvalidRequest" {
    try std.testing.expectError(
        error.InvalidRequest,
        zix.Http1.parseHead("\r\n\r\n"),
    );
}

test "zix edge: Http1 parseHead missing HTTP version returns InvalidRequest" {
    try std.testing.expectError(
        error.InvalidRequest,
        zix.Http1.parseHead("GET /\r\n\r\n"),
    );
}

test "zix edge: Http1 queryParam key with empty value returns empty string not null" {
    const result = try zix.Http1.parseHead("GET /path?key= HTTP/1.1\r\n\r\n");
    const val = zix.Http1.queryParam(&result.head, "key");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("", val.?);
}

test "zix edge: Http1 queryParam absent key returns null" {
    const result = try zix.Http1.parseHead("GET /path?other=x HTTP/1.1\r\n\r\n");
    try std.testing.expect(zix.Http1.queryParam(&result.head, "key") == null);
}

test "zix edge: Http1 parseRange start beyond total returns null" {
    try std.testing.expect(zix.Http1.parseRange("bytes=500-", 200) == null);
}

test "zix edge: Http1 parseRange missing bytes= prefix returns null" {
    try std.testing.expect(zix.Http1.parseRange("0-99", 200) == null);
}

test "zix edge: Http1 percentDecode encoded space decoded in place" {
    var buf = [_]u8{ 'a', '%', '2', '0', 'b' };
    const decoded = zix.Http1.percentDecode(&buf);
    try std.testing.expectEqualStrings("a b", decoded);
}
