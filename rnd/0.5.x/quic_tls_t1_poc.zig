//! QUIC-TLS PoC, phase T1 (http3-plan.md): RFC 9001 section 4 (carrying TLS messages) and 4.1 /
//! 5.1 (encryption levels and the per-level "quic" keys).
//!
//! Note:
//! - Layers C and Q proved the crypto and the wire format. Layer T joins them to TLS 1.3. T1 is the
//!   join point: in QUIC the TLS handshake does NOT use the TLS record layer, the handshake messages
//!   are carried directly as the payload of CRYPTO frames (19.6), reassembled by offset into one
//!   ordered stream per encryption level. QUIC packet protection replaces TLS record protection.
//! - There are four encryption levels (Initial, 0-RTT, Handshake, 1-RTT). Each derives its packet
//!   key / iv / hp from that level's TLS secret with the same "quic key" / "quic iv" / "quic hp"
//!   labels (5.1). T1 shows the level abstraction: Initial keys come from the DCID (as in C1) and
//!   1-RTT keys from the application secret (as in C3), both through the identical derivation.
//! - The oracle is the RFC text plus the C1 / C3 published vectors the per-level derivation reduces
//!   to. The CRYPTO reassembly (out-of-order, gap, overlap) and the no-record-framing property are
//!   the new T1 logic, exercised in process. The shipped engine reuses src/tls/key_schedule.zig.
//!
//! Run:    zig run rnd/0.5.x/quic_tls_t1_poc.zig
//! Verify: bash rnd/0.5.x/verify-quic-tls-t1.sh

const std = @import("std");

const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

const hash_length = Sha256.digest_length;

/// A schedule secret, one SHA-256 block wide.
const Secret = [hash_length]u8;

/// The QUIC version 1 Initial salt (RFC 9001 5.2).
const initial_salt = [_]u8{ 0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17, 0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad, 0xcc, 0xbb, 0x7f, 0x0a };

// --------------------------------------------------------------- //

/// HKDF-Expand-Label (RFC 8446 7.1): the "tls13 " prefix, the bare label, and a context.
fn expandLabel(out: []u8, secret: Secret, label: []const u8, context: []const u8) void {
    const prefix = "tls13 ";

    var info: [2 + 1 + prefix.len + 255 + 1 + hash_length]u8 = undefined;
    std.mem.writeInt(u16, info[0..2], @intCast(out.len), .big);
    info[2] = @intCast(prefix.len + label.len);
    @memcpy(info[3 .. 3 + prefix.len], prefix);
    @memcpy(info[3 + prefix.len .. 3 + prefix.len + label.len], label);

    const context_pos = 3 + prefix.len + label.len;
    info[context_pos] = @intCast(context.len);
    @memcpy(info[context_pos + 1 .. context_pos + 1 + context.len], context);

    HkdfSha256.expand(out, info[0 .. context_pos + 1 + context.len], secret);
}

/// The four QUIC encryption levels (RFC 9001 4.1). Each has its own packet number space and keys.
const EncryptionLevel = enum { initial, zero_rtt, handshake, application };

/// Derive a level's packet-protection key with the "quic key" label (RFC 9001 5.1). The key width
/// follows the negotiated AEAD: 16 bytes for AES-128-GCM, 32 for ChaCha20-Poly1305. The same
/// derivation runs at every level, only the input secret and width change.
fn quicKey(out: []u8, secret: Secret) void {
    expandLabel(out, secret, "quic key", "");
}

/// Derive the client Initial secret from the Destination Connection ID (RFC 9001 5.2).
fn clientInitialSecret(dcid: []const u8) Secret {
    const initial = HkdfSha256.extract(&initial_salt, dcid);

    var client: Secret = undefined;
    expandLabel(&client, initial, "client in", "");

    return client;
}

// --------------------------------------------------------------- //

/// A single CRYPTO stream that reassembles offset-addressed handshake bytes for one encryption
/// level (RFC 9001 4, RFC 9000 19.6). There is no TLS record framing: the bytes inserted are the
/// raw TLS handshake messages, and the contiguous prefix is what TLS may consume.
const CryptoStream = struct {
    buf: [512]u8 = undefined,
    present: [512]bool = @splat(false),

    /// Insert a CRYPTO frame's data at its offset. Overlapping or duplicate bytes are idempotent
    /// (RFC 9000 2.2: the data at an offset MUST NOT change).
    fn insert(self: *CryptoStream, offset: usize, data: []const u8) void {
        @memcpy(self.buf[offset .. offset + data.len], data);
        for (offset..offset + data.len) |i| self.present[i] = true;
    }

    /// The length of the contiguous handshake prefix available from offset 0 (RFC 9001 4): bytes
    /// past a gap are held back until the gap is filled.
    fn readableLen(self: CryptoStream) usize {
        var n: usize = 0;
        while (n < self.present.len and self.present[n]) n += 1;

        return n;
    }

    /// The contiguous handshake bytes ready for TLS to consume.
    fn readable(self: *const CryptoStream) []const u8 {
        return self.buf[0..self.readableLen()];
    }
};

// --------------------------------------------------------------- //

/// Decode a hex literal (no separators) into a freshly allocated byte slice.
fn hex(allocator: std.mem.Allocator, comptime text: []const u8) ![]u8 {
    const bytes = try allocator.alloc(u8, text.len / 2);
    _ = try std.fmt.hexToBytes(bytes, text);

    return bytes;
}

/// Report a boolean expectation and flag a failure.
fn expect(failures: *usize, name: []const u8, ok: bool) void {
    if (ok) {
        std.debug.print("  ok    {s}\n", .{name});
    } else {
        std.debug.print("  FAIL  {s}\n", .{name});
        failures.* += 1;
    }
}

/// Compare a byte slice against the expected hex and flag a failure.
fn expectBytes(failures: *usize, name: []const u8, actual: []const u8, comptime expected_hex: []const u8) void {
    var expected: [expected_hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected, expected_hex) catch unreachable;

    if (actual.len == expected.len and std.mem.eql(u8, actual, &expected)) {
        std.debug.print("  ok    {s}\n", .{name});
    } else {
        std.debug.print("  FAIL  {s}\n", .{name});
        std.debug.print("        want {s}\n", .{expected_hex});
        std.debug.print("        got  {x}\n", .{actual});
        failures.* += 1;
    }
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var failures: usize = 0;

    std.debug.print("RFC 9001 4 / RFC 9000 19.6: CRYPTO-frame handshake reassembly\n", .{});

    // A short ClientHello-shaped handshake message: type 0x01, 3-byte length 4, then a 4-byte body.
    const client_hello = try hex(arena, "0100000401020304");

    // In-order delivery reassembles to the original bytes.
    var in_order = CryptoStream{};
    in_order.insert(0, client_hello[0..4]);
    in_order.insert(4, client_hello[4..8]);
    expectBytes(&failures, "in-order reassembly", in_order.readable(), "0100000401020304");

    // Out-of-order delivery (second frame first) reassembles to the same bytes once the gap fills.
    var out_of_order = CryptoStream{};
    out_of_order.insert(4, client_hello[4..8]);
    expect(&failures, "tail before gap fill withholds everything", out_of_order.readableLen() == 0);
    out_of_order.insert(0, client_hello[0..4]);
    expectBytes(&failures, "out-of-order reassembly after gap fill", out_of_order.readable(), "0100000401020304");

    // A duplicate / overlapping frame is idempotent.
    var overlap = CryptoStream{};
    overlap.insert(0, client_hello[0..6]);
    overlap.insert(2, client_hello[2..8]);
    expectBytes(&failures, "overlapping frames idempotent", overlap.readable(), "0100000401020304");

    std.debug.print("RFC 9001 4: no TLS record protection (handshake-layer bytes)\n", .{});

    // The reassembled bytes are a TLS handshake message: they begin with the Handshake type
    // (0x01 ClientHello), NOT a TLS record ContentType (0x16) or a 5-byte record header.
    const ready = in_order.readable();
    expect(&failures, "starts with handshake type ClientHello (0x01)", ready[0] == 0x01);
    expect(&failures, "not wrapped in a TLS record (no 0x16 ContentType)", ready[0] != 0x16);

    std.debug.print("RFC 9001 5.1: per-level quic key derivation\n", .{});

    // Initial level: a 16-byte AES-128-GCM key from the DCID-derived client secret (the C1 vector).
    const dcid = try hex(arena, "8394c8f03e515708");
    var initial_key: [16]u8 = undefined;
    quicKey(&initial_key, clientInitialSecret(dcid));
    expectBytes(&failures, "Initial level client key (from DCID)", &initial_key, "1f369613dd76d5467730efcbe3b1a22d");

    // Application (1-RTT) level: the same "quic key" derivation over the application secret, here a
    // 32-byte ChaCha20-Poly1305 key (the C3 / A.5 vector). Same derivation, different level + AEAD.
    var app_secret: Secret = undefined;
    _ = try std.fmt.hexToBytes(&app_secret, "9ac312a7f877468ebe69422748ad00a15443f18203a07d6060f688f30f21632b");
    var app_key: [32]u8 = undefined;
    quicKey(&app_key, app_secret);
    expectBytes(&failures, "Application level key (from app secret)", &app_key, "c6d98ff3441c3fe1b2182094f69caa2ed4b716b65488960a7a984979fb23e1c8");

    // Distinct levels carry distinct secrets, hence distinct keys.
    expect(&failures, "level keys are independent", !std.mem.eql(u8, &initial_key, app_key[0..16]));
    const levels = [_]EncryptionLevel{ .initial, .zero_rtt, .handshake, .application };
    expect(&failures, "four encryption levels enumerated", levels.len == 4);

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("PASS: all RFC 9001 T1 CRYPTO + per-level key checks hold\n", .{});
    } else {
        std.debug.print("FAIL: {d} check(s) failed\n", .{failures});
        std.process.exit(1);
    }
}
