//! zix utils pwhash scrypt

const std = @import("std");

// --------------------------------------------------------- //

/// Scrypt pwhash create (crypt or PHC format)
pub fn hash(
    io: std.Io,
    allocator: std.mem.Allocator,
    password: []const u8,
    params: std.crypto.pwhash.scrypt.Params,
    encoding: std.crypto.pwhash.Encoding,
    buf: []u8,
) ![]const u8 {
    return try std.crypto.pwhash.scrypt.strHash(
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

/// Scrypt pwhash verify
pub fn verify(
    allocator: std.mem.Allocator,
    password_raw: []const u8,
    password_encoded: []const u8,
) !void {
    std.crypto.pwhash.scrypt.strVerify(
        password_encoded,
        password_raw,
        .{.allocator = allocator },
    ) catch |err| {
        return err;
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //


test "zix utils: pwhash scrypt hash & verify" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const password = "my sUp3r p4s5w0rd!";
    const mode = std.crypto.pwhash.Encoding.phc;

    var buf: [128]u8 = undefined;
    // const params = std.crypto.pwhash.scrypt.Params.owasp; // expensive for test
    var params = std.crypto.pwhash.scrypt.Params.sensitive;
    params.ln = 2;
    params.r = 2048;
    params.p = 1;

    const encoded = try hash(io, allocator, password, params, mode, &buf);
    try verify(allocator, password, encoded);

    try std.testing.expectError(error.PasswordVerificationFailed, verify(allocator, "wrong password", encoded));
}
