//! zix utils pwhash argon2

const std = @import("std");

// --------------------------------------------------------- //

/// Argon2 pwhash create (crypt or PHC format)
pub fn hash(
    io: std.Io,
    allocator: std.mem.Allocator,
    password: []const u8,
    params: std.crypto.pwhash.argon2.Params,
    encoding: std.crypto.pwhash.Encoding,
    buf: []u8,
) ![]const u8 {
    return try std.crypto.pwhash.argon2.strHash(
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

/// Aargon2 pwhash verify
pub fn verify(
    io: std.Io,
    allocator: std.mem.Allocator,
    password_raw: []const u8,
    password_encoded: []const u8,
) !void {
    std.crypto.pwhash.argon2.strVerify(
        password_encoded,
        password_raw,
        .{.allocator = allocator },
        io,
    ) catch |err| {
        return err;
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //


test "zix utils: pwhash argon2 hash & verify" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const password = "my sUp3r p4s5w0rd!";
    const mode = std.crypto.pwhash.Encoding.phc;

    var buf: [128]u8 = undefined;
    // const params = std.crypto.pwhash.argon2.Params.owasp_2id; // expensive for test
    var params = std.crypto.pwhash.argon2.Params.sensitive_2id;
    params.t = 2;
    params.m = 2048;
    params.p = 1;

    const encoded = try hash(io, allocator, password, params, mode, &buf);
    try verify(io, allocator, password, encoded);

    try std.testing.expectError(error.PasswordVerificationFailed, verify(io, allocator, "wrong password", encoded));
}
