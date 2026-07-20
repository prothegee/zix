//! Minimal SCRAM-SHA-256 client (no channel binding), std.crypto only.
//! Ported from src/driver/postgrez/src/auth/scram.zig, trimmed to what the
//! cleartext PoC needs.

const std = @import("std");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Scram = struct {
    password: []const u8,
    client_first_bare: [128]u8 = undefined,
    client_first_bare_len: usize = 0,
    salted: [32]u8 = undefined,
    auth_message: [2048]u8 = undefined,
    auth_message_len: usize = 0,
    final: [1024]u8 = undefined,
    final_len: usize = 0,

    pub fn init(password: []const u8, nonce_text: []const u8) Scram {
        var self = Scram{ .password = password };

        var writer = std.Io.Writer.fixed(&self.client_first_bare);
        writer.writeAll("n=,r=") catch unreachable;
        writer.writeAll(nonce_text) catch unreachable;
        self.client_first_bare_len = writer.buffered().len;

        return self;
    }

    pub fn clientFirst(self: *Scram, out: []u8) []const u8 {
        const gs2 = "n,,";
        @memcpy(out[0..gs2.len], gs2);
        @memcpy(out[gs2.len..][0..self.client_first_bare_len], self.client_first_bare[0..self.client_first_bare_len]);

        return out[0 .. gs2.len + self.client_first_bare_len];
    }

    pub fn handleServerFirst(self: *Scram, server_first: []const u8) ![]const u8 {
        var full_nonce: []const u8 = "";
        var salt_b64: []const u8 = "";
        var iterations: u32 = 0;

        var part_it = std.mem.splitScalar(u8, server_first, ',');
        while (part_it.next()) |part| {
            if (attr(part, 'r')) |value| {
                full_nonce = value;
            } else if (attr(part, 's')) |value| {
                salt_b64 = value;
            } else if (attr(part, 'i')) |value| {
                iterations = try std.fmt.parseInt(u32, value, 10);
            }
        }
        if (full_nonce.len == 0 or salt_b64.len == 0 or iterations == 0) return error.BadServerFirst;

        var salt: [64]u8 = undefined;
        const salt_len = try std.base64.standard.Decoder.calcSizeForSlice(salt_b64);
        if (salt_len > salt.len) return error.BadServerFirst;
        try std.base64.standard.Decoder.decode(salt[0..salt_len], salt_b64);

        try std.crypto.pwhash.pbkdf2(&self.salted, self.password, salt[0..salt_len], iterations, HmacSha256);

        // client-final-without-proof: c=biws (base64 of the "n,," gs2 header), r=<full nonce>
        var final_writer = std.Io.Writer.fixed(&self.final);
        final_writer.writeAll("c=biws,r=") catch return error.TooLong;
        final_writer.writeAll(full_nonce) catch return error.TooLong;

        var auth_writer = std.Io.Writer.fixed(&self.auth_message);
        auth_writer.writeAll(self.client_first_bare[0..self.client_first_bare_len]) catch return error.TooLong;
        auth_writer.writeAll(",") catch return error.TooLong;
        auth_writer.writeAll(server_first) catch return error.TooLong;
        auth_writer.writeAll(",") catch return error.TooLong;
        auth_writer.writeAll(final_writer.buffered()) catch return error.TooLong;
        self.auth_message_len = auth_writer.buffered().len;

        var client_key: [32]u8 = undefined;
        HmacSha256.create(&client_key, "Client Key", &self.salted);

        var stored_key: [32]u8 = undefined;
        Sha256.hash(&client_key, &stored_key, .{});

        var client_signature: [32]u8 = undefined;
        HmacSha256.create(&client_signature, self.auth_message[0..self.auth_message_len], &stored_key);

        var proof: [32]u8 = undefined;
        for (&proof, client_key, client_signature) |*out_byte, key_byte, sig_byte| {
            out_byte.* = key_byte ^ sig_byte;
        }

        var proof_b64: [std.base64.standard.Encoder.calcSize(32)]u8 = undefined;
        const proof_encoded = std.base64.standard.Encoder.encode(&proof_b64, &proof);
        final_writer.writeAll(",p=") catch return error.TooLong;
        final_writer.writeAll(proof_encoded) catch return error.TooLong;
        self.final_len = final_writer.buffered().len;

        return self.final[0..self.final_len];
    }
};

fn attr(part: []const u8, code: u8) ?[]const u8 {
    if (part.len < 2 or part[0] != code or part[1] != '=') return null;

    return part[2..];
}

var nonce_counter: std.atomic.Value(u64) = .init(0);

/// A fresh (not cryptographic) client nonce. SCRAM only needs it unique per
/// exchange, so a clock plus counter seed is enough for the PoC.
pub fn randomNonce(out: *[24]u8) void {
    var timespec: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &timespec);

    const seed = (@as(u64, @intCast(timespec.sec)) *% 1_000_000_000 +% @as(u64, @intCast(timespec.nsec))) ^
        (nonce_counter.fetchAdd(1, .monotonic) *% 0x9E37_79B9_7F4A_7C15);

    var prng = std.Random.DefaultPrng.init(seed);
    var raw: [18]u8 = undefined;
    prng.random().bytes(&raw);

    _ = std.base64.standard.Encoder.encode(out, &raw);
}
