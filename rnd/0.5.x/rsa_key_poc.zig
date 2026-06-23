//! RSA signing PoC, phase R3 (rsa-plan.md): parse an RSA private key from PEM (PKCS#1 or PKCS#8),
//! then sign with the parsed key. This retires the raw n / d hex arguments of the R1 / R2 PoCs.
//!
//! Note:
//! - Two key forms are accepted. PKCS#1 (`-----BEGIN RSA PRIVATE KEY-----`, RFC 8017 A.1.2) is the
//!   bare RSAPrivateKey SEQUENCE. PKCS#8 (`-----BEGIN PRIVATE KEY-----`, RFC 5208) wraps that same
//!   SEQUENCE in a PrivateKeyInfo with an rsaEncryption AlgorithmIdentifier, so the inner key is the
//!   content of the final OCTET STRING.
//! - The DER reader mirrors src/tls/pem.zig (the form openssl emits). An INTEGER may carry one
//!   leading 0x00 to stay positive when the top bit is set, so the magnitude strips leading zeros.
//! - The round-trip gate is two-fold (verify-rsa.sh): the parsed modulus printed to stdout must
//!   equal `openssl rsa -modulus`, and the PKCS#1 v1.5 signature produced with the parsed n and d
//!   must be byte-identical to `openssl dgst -sign`. A byte-exact signature proves both n and d were
//!   parsed correctly, since a wrong value in either changes the output.
//! - CRT parameters (p, q, dp, dq, qinv) are parsed and length-checked here even though the plain
//!   `m ^ d mod n` path does not use them. They are the optional speed lever folded in later.
//!
//! Usage:
//! ```zig
//! // argv: <key_pem_path> <message> <sig_out_path>
//! //   key_pem_path - an RSA private key, PEM, PKCS#1 or PKCS#8
//! //   message - the bytes to sign (hashed with SHA-256 internally)
//! //   sig_out_path - where the raw PKCS#1 v1.5 signature (k bytes) is written
//! ```
//!
//! Run: zig run rnd/0.5.x/rsa_key_poc.zig -- <key_pem_path> <message> <sig_out_path>

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// Upper bound on the modulus size this PoC accepts (RSA-4096). RSA-2048 keys use a subset.
const max_modulus_bits = 4096;

const Modulus = std.crypto.ff.Modulus(max_modulus_bits);

/// DigestInfo DER prefix for SHA-256 (RFC 8017 9.2, the T value is this prefix then the 32 hash bytes).
const sha256_digestinfo_prefix = [_]u8{
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86,
    0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05,
    0x00, 0x04, 0x20,
};

/// The fields of a two-prime RSAPrivateKey (RFC 8017 A.1.2), each as a big-endian magnitude slice
/// into the parsed DER (leading zero stripped).
const RsaPrivateKey = struct {
    n: []const u8,
    e: []const u8,
    d: []const u8,
    p: []const u8,
    q: []const u8,
    dp: []const u8,
    dq: []const u8,
    qinv: []const u8,
};

pub fn main(process: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const io = process.io;

    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();

    const key_path = arg_iter.next() orelse return error.UsageNeedsThreeArgs;
    const message = arg_iter.next() orelse return error.UsageNeedsThreeArgs;
    const out_path = arg_iter.next() orelse return error.UsageNeedsThreeArgs;

    const cwd = std.Io.Dir.cwd();
    const pem = try cwd.readFileAlloc(io, key_path, arena, .unlimited);

    const der = try pemToDer(arena, pem);
    const is_pkcs8 = std.mem.indexOf(u8, pem, "BEGIN RSA PRIVATE KEY") == null;
    const key = try parseRsaPrivateKey(der, is_pkcs8);

    try printModulusHex(io, key.n);

    const k = key.n.len;

    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(message, &digest, .{});

    var em_buf: [max_modulus_bits / 8]u8 = undefined;
    const em = em_buf[0..k];
    try emsaPkcs1V15(digest, em);

    var sig_buf: [max_modulus_bits / 8]u8 = undefined;
    const sig = sig_buf[0..k];
    try rsasp1(key.n, key.d, em, sig);

    const file = try cwd.createFile(io, out_path, .{});
    defer file.close(io);

    var write_buf: [max_modulus_bits / 8]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try writer.interface.writeAll(sig);
    try writer.interface.flush();
}

/// Decode a PEM document body to DER, allocating the output from `arena`.
fn pemToDer(arena: std.mem.Allocator, pem: []const u8) ![]const u8 {
    var b64: std.ArrayList(u8) = .empty;

    var lines = std.mem.tokenizeScalar(u8, pem, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or std.mem.startsWith(u8, line, "-----")) continue;

        try b64.appendSlice(arena, line);
    }

    const decoder = std.base64.standard.Decoder;
    const der_len = try decoder.calcSizeForSlice(b64.items);
    const out = try arena.alloc(u8, der_len);
    try decoder.decode(out, b64.items);

    return out;
}

/// Parse a two-prime RSAPrivateKey, unwrapping the PKCS#8 PrivateKeyInfo first when `is_pkcs8`.
///
/// Note:
/// - PKCS#8 (RFC 5208): SEQUENCE { INTEGER version, SEQUENCE AlgorithmIdentifier, OCTET STRING }.
///   The OCTET STRING content is the inner RSAPrivateKey, which is then parsed as PKCS#1.
/// - PKCS#1 (RFC 8017 A.1.2): SEQUENCE { version, n, e, d, p, q, dp, dq, qinv }.
///
/// Param:
/// der - []const u8 (the decoded key DER)
/// is_pkcs8 - bool (true when the armor was the generic PRIVATE KEY, not RSA PRIVATE KEY)
///
/// Return:
/// - RsaPrivateKey (slices into `der`)
fn parseRsaPrivateKey(der: []const u8, is_pkcs8: bool) !RsaPrivateKey {
    var inner = der;
    if (is_pkcs8) {
        var outer = DerReader{ .buf = der };

        try outer.expectTag(0x30); // SEQUENCE PrivateKeyInfo
        _ = try outer.readLen();
        try outer.expectTag(0x02); // INTEGER version
        try outer.skip(try outer.readLen());
        try outer.expectTag(0x30); // SEQUENCE AlgorithmIdentifier
        try outer.skip(try outer.readLen());
        try outer.expectTag(0x04); // OCTET STRING privateKey
        const inner_len = try outer.readLen();
        inner = try outer.read(inner_len);
    }

    var r = DerReader{ .buf = inner };

    try r.expectTag(0x30); // SEQUENCE RSAPrivateKey
    _ = try r.readLen();
    try r.expectTag(0x02); // INTEGER version (0 for two-prime)
    try r.skip(try r.readLen());

    return .{
        .n = try r.readInteger(),
        .e = try r.readInteger(),
        .d = try r.readInteger(),
        .p = try r.readInteger(),
        .q = try r.readInteger(),
        .dp = try r.readInteger(),
        .dq = try r.readInteger(),
        .qinv = try r.readInteger(),
    };
}

/// Encode the SHA-256 digest as an EMSA-PKCS1-v1_5 message (RFC 8017 9.2).
fn emsaPkcs1V15(digest: [Sha256.digest_length]u8, em: []u8) !void {
    const t_len = sha256_digestinfo_prefix.len + Sha256.digest_length;
    if (em.len < t_len + 11) return error.IntendedEncodedMessageLengthTooShort;

    @memset(em, 0xff);
    em[0] = 0x00;
    em[1] = 0x01;
    em[em.len - t_len - 1] = 0x00;

    @memcpy(em[em.len - t_len ..][0..sha256_digestinfo_prefix.len], &sha256_digestinfo_prefix);
    @memcpy(em[em.len - Sha256.digest_length ..][0..Sha256.digest_length], &digest);
}

/// RSASP1 signature primitive (RFC 8017 5.2.1): s = m ^ d mod n, then I2OSP to k bytes.
fn rsasp1(n_bytes: []const u8, d_bytes: []const u8, em: []const u8, sig: []u8) !void {
    const modulus = try Modulus.fromBytes(n_bytes, .big);
    const m_fe = try Modulus.Fe.fromBytes(modulus, em, .big);

    const s_fe = try modulus.powWithEncodedExponent(m_fe, d_bytes, .big);

    try s_fe.toBytes(sig, .big);
}

/// Write the modulus as lowercase hex plus a newline to stdout (the round-trip artifact).
fn printModulusHex(io: std.Io, modulus: []const u8) !void {
    const hex_digits = "0123456789abcdef";

    var line: [max_modulus_bits / 8 * 2 + 1]u8 = undefined;
    var pos: usize = 0;
    for (modulus) |b| {
        line[pos] = hex_digits[b >> 4];
        line[pos + 1] = hex_digits[b & 0x0f];
        pos += 2;
    }
    line[pos] = '\n';
    pos += 1;

    var buf: [max_modulus_bits / 8 * 2 + 1]u8 = undefined;
    const stdout = std.Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    try writer.interface.writeAll(line[0..pos]);
    try writer.interface.flush();
}

const DerReader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn byte(self: *DerReader) !u8 {
        if (self.pos >= self.buf.len) return error.InvalidKey;

        const b = self.buf[self.pos];
        self.pos += 1;

        return b;
    }

    fn expectTag(self: *DerReader, tag: u8) !void {
        if (try self.byte() != tag) return error.InvalidKey;
    }

    fn readLen(self: *DerReader) !usize {
        const first = try self.byte();
        if (first < 0x80) return first;

        const count = first & 0x7f;
        if (count == 0 or count > 2) return error.InvalidKey;

        var len: usize = 0;
        var i: usize = 0;
        while (i < count) : (i += 1) len = (len << 8) | (try self.byte());

        return len;
    }

    fn skip(self: *DerReader, n: usize) !void {
        if (self.pos + n > self.buf.len) return error.InvalidKey;
        self.pos += n;
    }

    fn read(self: *DerReader, n: usize) ![]const u8 {
        if (self.pos + n > self.buf.len) return error.InvalidKey;

        const s = self.buf[self.pos .. self.pos + n];
        self.pos += n;

        return s;
    }

    /// Read an INTEGER and return its big-endian magnitude (leading 0x00 padding stripped).
    fn readInteger(self: *DerReader) ![]const u8 {
        try self.expectTag(0x02);

        const len = try self.readLen();
        var content = try self.read(len);
        while (content.len > 1 and content[0] == 0x00) content = content[1..];

        return content;
    }
};
