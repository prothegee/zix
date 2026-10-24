//! zix utils pwhash bcrypt

const std = @import("std");

// --------------------------------------------------------- //

/// Bcrypt pwhash create (crypt or PHC format)
pub fn hash(
    io: std.Io,
    allocator: std.mem.Allocator,
    password: []const u8,
    params: std.crypto.pwhash.bcrypt.Params,
    encoding: std.crypto.pwhash.Encoding,
    buf: []u8,
) ![]const u8 {
    return try std.crypto.pwhash.bcrypt.strHash(
        password,
        .{
            .allocator = allocator,
            .params = params,
            .encoding = encoding,
        },
        buf,
        io,
    );
}

/// Bcrypt pwhash verify
pub fn verify(
    allocator: std.mem.Allocator,
    password_raw: []const u8,
    password_encoded: []const u8,
) !void {
    try std.crypto.pwhash.bcrypt.strVerify(
        password_encoded,
        password_raw,
        .{
            .allocator = allocator,
            .silently_truncate_password = false,
        },
    );
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //


test "zix utils: pwhash bcrypt hash & verify" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const password = "my sUp3r p4s5w0rd!";
    const encoding = std.crypto.pwhash.Encoding.crypt;

    var buf: [128]u8 = undefined;
    const params = std.crypto.pwhash.bcrypt.Params.owasp;

    const encoded = try hash(io, allocator, password, params, encoding, &buf);
    try verify(allocator, password, encoded);

    try std.testing.expectError(
        error.PasswordVerificationFailed,
        verify(allocator, "wrong password", encoded),
    );
}
