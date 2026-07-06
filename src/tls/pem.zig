//! PEM + minimal DER decode for loading the server certificate and ECDSA private key.
//!
//! Note:
//! - `pemToDer` strips the -----BEGIN/END----- armor and base64-decodes the body. The
//!   certificate DER feeds the Certificate message as-is. `ecdsaScalarFromSec1` extracts the
//!   raw 32-byte private scalar from a SEC1 ECPrivateKey (RFC 5915, the form `openssl ecparam
//!   -genkey` emits), and `ed25519SeedFromPkcs8` extracts the 32-byte seed from a PKCS#8
//!   PrivateKeyInfo (RFC 8410, the form `openssl genpkey -algorithm ed25519` emits). Full X.509
//!   parsing is a separate concern.

const std = @import("std");

pub const Error = error{ InvalidPem, InvalidKey, BufferTooSmall };

/// Base64 accumulation buffer: caps the max PEM cert or key document size.
const MAX_PEM_BYTES: usize = 16384;

// --------------------------------------------------------------- //

/// Decode a PEM document body to DER into `out`, returning the DER slice.
pub fn pemToDer(out: []u8, pem: []const u8) ![]const u8 {
    var b64: [MAX_PEM_BYTES]u8 = undefined;
    var n: usize = 0;

    var lines = std.mem.tokenizeScalar(u8, pem, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or std.mem.startsWith(u8, line, "-----")) continue;
        if (n + line.len > b64.len) return error.BufferTooSmall;

        @memcpy(b64[n..][0..line.len], line);
        n += line.len;
    }

    const decoder = std.base64.standard.Decoder;
    const der_len = decoder.calcSizeForSlice(b64[0..n]) catch return error.InvalidPem;
    if (der_len > out.len) return error.BufferTooSmall;
    decoder.decode(out[0..der_len], b64[0..n]) catch return error.InvalidPem;

    return out[0..der_len];
}

/// Extract the 32-byte private scalar from a SEC1 ECPrivateKey DER (RFC 5915):
/// SEQUENCE { INTEGER version(1), OCTET STRING privateKey(32), ... }.
pub fn ecdsaScalarFromSec1(der: []const u8) ![32]u8 {
    var r = DerReader{ .buf = der };

    try r.expectTag(0x30); // SEQUENCE
    _ = try r.readLen();
    try r.expectTag(0x02); // INTEGER version
    try r.skip(try r.readLen());
    try r.expectTag(0x04); // OCTET STRING privateKey
    if (try r.readLen() != 32) return error.InvalidKey;

    var out: [32]u8 = undefined;
    @memcpy(&out, try r.read(32));

    return out;
}

/// Extract the 32-byte Ed25519 seed from a PKCS#8 PrivateKeyInfo DER (RFC 8410): SEQUENCE {
/// INTEGER version, SEQUENCE { OID 1.3.101.112 }, OCTET STRING { OCTET STRING privateKey(32) } }.
/// This is the form `openssl genpkey -algorithm ed25519` emits.
pub fn ed25519SeedFromPkcs8(der: []const u8) ![32]u8 {
    var r = DerReader{ .buf = der };

    try r.expectTag(0x30); // SEQUENCE PrivateKeyInfo
    _ = try r.readLen();
    try r.expectTag(0x02); // INTEGER version
    try r.skip(try r.readLen());
    try r.expectTag(0x30); // SEQUENCE AlgorithmIdentifier
    try r.skip(try r.readLen());
    try r.expectTag(0x04); // OCTET STRING privateKey
    _ = try r.readLen();
    try r.expectTag(0x04); // inner OCTET STRING CurvePrivateKey
    if (try r.readLen() != 32) return error.InvalidKey;

    var out: [32]u8 = undefined;
    @memcpy(&out, try r.read(32));

    return out;
}

const DerReader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn byte(self: *DerReader) Error!u8 {
        if (self.pos >= self.buf.len) return error.InvalidKey;

        const b = self.buf[self.pos];
        self.pos += 1;

        return b;
    }

    fn expectTag(self: *DerReader, tag: u8) Error!void {
        if (try self.byte() != tag) return error.InvalidKey;
    }

    fn readLen(self: *DerReader) Error!usize {
        const first = try self.byte();
        if (first < 0x80) return first;

        const count = first & 0x7f;
        if (count == 0 or count > 2) return error.InvalidKey;

        var len: usize = 0;
        var i: usize = 0;
        while (i < count) : (i += 1) len = (len << 8) | (try self.byte());

        return len;
    }

    fn skip(self: *DerReader, n: usize) Error!void {
        if (self.pos + n > self.buf.len) return error.InvalidKey;
        self.pos += n;
    }

    fn read(self: *DerReader, n: usize) Error![]const u8 {
        if (self.pos + n > self.buf.len) return error.InvalidKey;

        const s = self.buf[self.pos .. self.pos + n];
        self.pos += n;

        return s;
    }
};

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

test "zix test: pem, SEC1 ECDSA key -> 32-byte scalar (fixture)" {
    const key_pem =
        \\-----BEGIN EC PRIVATE KEY-----
        \\MHcCAQEEIAt29/HHv24gAp3bVmeV5Y2lumP/vbkUv2mb++0xR9MsoAoGCCqGSM49
        \\AwEHoUQDQgAEwqASGymKyc04kgDnjZTnveHMfNgHR5X6tPkZeZ1A/cIxxakJkKyM
        \\YWauRy8z90/O0Jfy7be4oZdL5mpKsH8lOw==
        \\-----END EC PRIVATE KEY-----
    ;

    var der_buf: [256]u8 = undefined;
    const der = try pemToDer(&der_buf, key_pem);
    const scalar = try ecdsaScalarFromSec1(der);

    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "0b76f7f1c7bf6e20029ddb566795e58da5ba63ffbdb914bf699bfbed3147d32c");
    try std.testing.expectEqualSlices(u8, &expected, &scalar);
}

test "zix test: pem, PKCS#8 Ed25519 key -> 32-byte seed (fixture)" {
    const key_pem =
        \\-----BEGIN PRIVATE KEY-----
        \\MC4CAQAwBQYDK2VwBCIEIFwpJTm6t3wxIBTGVqlD12tSAhCajuDznWINyTQWWiiM
        \\-----END PRIVATE KEY-----
    ;

    var der_buf: [128]u8 = undefined;
    const der = try pemToDer(&der_buf, key_pem);
    const seed = try ed25519SeedFromPkcs8(der);

    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "5c292539bab77c312014c656a943d76b5202109a8ee0f39d620dc934165a288c");
    try std.testing.expectEqualSlices(u8, &expected, &seed);

    // the seed must reconstruct a valid Ed25519 key pair.
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
    _ = kp;
}
