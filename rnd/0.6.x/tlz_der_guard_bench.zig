//! TLZ der_guard cost: std.crypto.Certificate.parse alone vs the bounds guard plus parse
//!
//! Note:
//! - Raw research copy of src/tlz/src/crypto/der_guard.zig (no src/ import), pinned at the
//!   version that fixed the std DER panic on truncated or crafted certificates.
//! - Measures three loops per certificate (ECDSA P-256 472 bytes, RSA-2048 803 bytes):
//!   guard only, parse only, guard + parse. For scale it also times one ECDSA verify.
//!
//! Result (2026-11-12, x86_64, ReleaseFast, 1,000,000 iterations):
//!   ecdsa guard 316 ns, parse 200 ns, guard + parse 534 ns
//!   rsa   guard 285 ns, parse 174 ns, guard + parse 479 ns
//!   ecdsa verify 142825 ns, so the guard is about 0.2% of one signature check.
//!
//! Run: zig run -O ReleaseFast rnd/0.6.x/tlz_der_guard_bench.zig
//!   Pass a smaller iteration count as argv[1] (default 1,000,000).

const std = @import("std");

const Element = std.crypto.Certificate.der.Element;

// --------------------------------------------------------- //
// Private:

/// Nesting cap, so a crafted certificate cannot exhaust the stack.
const MAX_DEPTH: usize = 16;

const TAG_BOOLEAN: u8 = 0x01;
const TAG_INTEGER: u8 = 0x02;
const TAG_BIT_STRING: u8 = 0x03;
const TAG_OCTET_STRING: u8 = 0x04;
const TAG_OID: u8 = 0x06;
const TAG_SEQUENCE: u8 = 0x30;
const TAG_VERSION: u8 = 0xa0;
const CONSTRUCTED_BIT: u8 = 0x20;

/// TBSCertificate fields std reads in order: serial, signature, issuer, validity,
/// subject, subjectPublicKeyInfo (RFC 5280 4.1).
const TBS_REQUIRED_FIELDS: usize = 6;

/// Certificate fields: tbsCertificate, signatureAlgorithm, signatureValue.
const CERTIFICATE_FIELDS: usize = 3;

/// rsaEncryption OID (1.2.840.113549.1.1.1) content bytes.
const RSA_ENCRYPTION_OID = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01 };

/// subjectAltName OID (2.5.29.17) content bytes.
const SUBJECT_ALT_NAME_OID = [_]u8{ 0x55, 0x1d, 0x11 };

fn tagOf(element: Element) u8 {
    return @bitCast(element.identifier);
}

fn contentOf(bytes: []const u8, element: Element) []const u8 {
    return bytes[element.slice.start..element.slice.end];
}

/// The child at `index` of an already checked constructed element.
fn childAt(bytes: []const u8, parent: Element, index: usize) ?Element {
    var pos: usize = parent.slice.start;
    var at: usize = 0;

    while (readElement(bytes, pos, parent.slice.end)) |child| {
        if (at == index) return child;

        at += 1;
        pos = child.slice.end;
    }

    return null;
}

fn countChildren(bytes: []const u8, parent: Element) usize {
    var pos: usize = parent.slice.start;
    var count: usize = 0;

    while (readElement(bytes, pos, parent.slice.end)) |child| {
        count += 1;
        pos = child.slice.end;
    }

    return count;
}

/// Every element in `[start, end)` is well formed and they fill the range exactly.
/// The first and last element and the count are reported in the same pass.
fn walkChildren(
    bytes: []const u8,
    start: usize,
    end: usize,
    depth: usize,
    first: *?Element,
    last: *?Element,
    count: *usize,
) bool {
    if (depth > MAX_DEPTH) return false;

    var pos = start;
    while (pos < end) {
        const element = readElement(bytes, pos, end) orelse return false;
        if (!checkElement(bytes, element, depth)) return false;

        if (count.* == 0) first.* = element;
        last.* = element;
        count.* += 1;
        pos = element.slice.end;
    }

    return true;
}

fn walk(bytes: []const u8, start: usize, end: usize, depth: usize) bool {
    var first: ?Element = null;
    var last: ?Element = null;
    var count: usize = 0;

    return walkChildren(bytes, start, end, depth, &first, &last, &count);
}

/// DER minimum lengths for the primitives std reads a byte of.
fn primitiveLengthOk(tag: u8, len: usize) bool {
    return switch (tag) {
        TAG_BOOLEAN => len == 1,
        TAG_INTEGER, TAG_BIT_STRING => len >= 1,
        else => true,
    };
}

fn checkElement(bytes: []const u8, element: Element, depth: usize) bool {
    const tag = tagOf(element);
    const len = element.slice.end - element.slice.start;
    if (!primitiveLengthOk(tag, len)) return false;

    if (tag & CONSTRUCTED_BIT == 0) return true;

    var first: ?Element = null;
    var last: ?Element = null;
    var count: usize = 0;
    const start = element.slice.start;
    const end = element.slice.end;
    if (!walkChildren(bytes, start, end, depth + 1, &first, &last, &count)) return false;
    if (tag != TAG_SEQUENCE or count == 0) return true;

    return checkSequence(bytes, first.?, last.?, count, depth);
}

/// Extension { OID, [critical], OCTET STRING }: std and PathConstraints read the
/// OCTET STRING content as DER, so it is walked too. subjectAltName content is
/// iterated by std, so its first element must be constructed.
fn checkExtensionValue(bytes: []const u8, first: Element, value: Element, depth: usize) bool {
    const content = contentOf(bytes, value);
    if (!walk(bytes, value.slice.start, value.slice.end, depth + 1)) return false;

    const is_san = std.mem.eql(u8, contentOf(bytes, first), &SUBJECT_ALT_NAME_OID);
    if (!is_san or content.len == 0) return true;

    const names = readElement(bytes, value.slice.start, value.slice.end) orelse return false;

    return tagOf(names) & CONSTRUCTED_BIT != 0;
}

/// SubjectPublicKeyInfo { AlgorithmIdentifier { rsaEncryption, ... }, BIT STRING }:
/// std reads the key bits as SEQUENCE { modulus, exponent }.
fn checkRsaKey(bytes: []const u8, key_bits: Element, depth: usize) bool {
    const start: usize = key_bits.slice.start + 1;
    const end: usize = key_bits.slice.end;
    if (start >= end or !walk(bytes, start, end, depth + 1)) return false;

    const key = readElement(bytes, start, end) orelse return false;
    if (tagOf(key) != TAG_SEQUENCE) return true;

    return countChildren(bytes, key) >= 2;
}

fn checkSequence(
    bytes: []const u8,
    first: Element,
    last: Element,
    count: usize,
    depth: usize,
) bool {
    if (count >= 2 and tagOf(first) == TAG_OID and tagOf(last) == TAG_OCTET_STRING) {
        return checkExtensionValue(bytes, first, last, depth);
    }

    const is_key_info = tagOf(first) == TAG_SEQUENCE and
        count == 2 and
        tagOf(last) == TAG_BIT_STRING;
    if (!is_key_info) return true;

    const algorithm = readElement(bytes, first.slice.start, first.slice.end) orelse return true;
    const is_rsa = tagOf(algorithm) == TAG_OID and
        std.mem.eql(u8, contentOf(bytes, algorithm), &RSA_ENCRYPTION_OID);
    if (!is_rsa) return true;

    return checkRsaKey(bytes, last, depth);
}

/// The fields std reads one after another must exist, so no read runs off the end.
fn checkCertificateShape(der: []const u8, root: Element) bool {
    if (countChildren(der, root) < CERTIFICATE_FIELDS) return false;

    const tbs = childAt(der, root, 0) orelse return false;
    if (tagOf(tbs) != TAG_SEQUENCE) return false;

    const first = childAt(der, tbs, 0) orelse return false;
    const has_version = tagOf(first) == TAG_VERSION;
    const required = TBS_REQUIRED_FIELDS + @intFromBool(has_version);

    return countChildren(der, tbs) >= required;
}

/// Read one element header at `pos` and check it fits before `end`. Mirrors std's
/// reader (long form up to 4 length bytes) with bounds checks.
///
/// Param:
/// bytes - []const u8 (the whole buffer)
/// pos - usize (where the element starts)
/// end - usize (the element must end at or before this)
///
/// Return:
/// - Element (slice indexes into `bytes`)
/// - null when the header or the content does not fit, or the length is indefinite
pub fn readElement(bytes: []const u8, pos: usize, end: usize) ?Element {
    if (end > bytes.len or pos >= end or end - pos < 2) return null;

    const size_byte = bytes[pos + 1];
    var start = pos + 2;
    var len: usize = size_byte;

    if (size_byte & 0x80 != 0) {
        const count = size_byte & 0x7f;
        if (count == 0 or count > 4 or count > end - start) return null;

        len = 0;
        for (bytes[start .. start + count]) |byte| len = (len << 8) | byte;
        start += count;
    }

    if (len > end - start) return null;

    return .{
        .identifier = @bitCast(bytes[pos]),
        .slice = .{
            .start = @intCast(start),
            .end = @intCast(start + len),
        },
    };
}

/// The certificate DER is safe to hand to std.crypto.Certificate.
///
/// Param:
/// der - []const u8 (one certificate, nothing after it)
///
/// Return:
/// - bool (false for truncated, oversized, or malformed DER)
pub fn isSafeCertificate(der: []const u8) bool {
    if (der.len > std.math.maxInt(u32)) return false;

    const root = readElement(der, 0, der.len) orelse return false;
    if (root.slice.end != der.len or tagOf(root) != TAG_SEQUENCE) return false;
    if (!checkElement(der, root, 0)) return false;

    return checkCertificateShape(der, root);
}

/// Self-signed ECDSA P-256 CN=localhost, SAN DNS:localhost + IP:127.0.0.1.
const EC_CERT_HEX =
    "308201d43082017ba00302010202147a26ee491f091ac7c914f4a810c1ece713402574300a06082a" ++
    "8648ce3d040302302a3112301006035504030c096c6f63616c686f737431143012060355040a0c0b" ++
    "7a69782d746c732d706f63301e170d3236303632323132353432305a170d33363036313931323534" ++
    "32305a302a3112301006035504030c096c6f63616c686f737431143012060355040a0c0b7a69782d" ++
    "746c732d706f633059301306072a8648ce3d020106082a8648ce3d03010703420004c2a0121b298a" ++
    "c9cd389200e78d94e7bde1cc7cd8074795fab4f919799d40fdc231c5a90990ac8c6166ae472f33f7" ++
    "4fced097f2edb7b8a1974be66a4ab07f253ba37f307d301d0603551d0e04160414c34e1d0a36a439" ++
    "47709b539e16dd0213aa4196aa301f0603551d23041830168014c34e1d0a36a43947709b539e16dd" ++
    "0213aa4196aa300f0603551d130101ff040530030101ff301a0603551d110413301182096c6f6361" ++
    "6c686f737487047f000001300e0603551d0f0101ff040403020780300a06082a8648ce3d04030203" ++
    "4700304402200b012f119db9b95d990bc482cb63e8f81e337a08634904e4caf513dc10c8aa830220" ++
    "2fdfe79ff6d5403e753ddf2aa52671923b8a2c28126bcbf196bd6fb7ecbcb14e";

/// Self-signed RSA-2048 CN=localhost, SAN DNS:localhost (openssl req -x509).
const RSA_CERT_HEX =
    "3082031f30820207a00302010202141a73adcd0d14a8b7f0c889e63278048c77b430f6300d06092a" ++
    "864886f70d01010b050030143112301006035504030c096c6f63616c686f7374301e170d32363031" ++
    "30313030303030305a170d3336303130313030303030305a30143112301006035504030c096c6f63" ++
    "616c686f737430820122300d06092a864886f70d01010105000382010f003082010a0282010100e2" ++
    "2bfba59611814ff323b35710ddbef1a8802d1f0323b93c675277b8daa537714ac4787dbf8d68d78c" ++
    "4781301aadf13629d455690e0faed8319425a75afabb45b0f559903ff4ec75065d87f26ba8707703" ++
    "aac239be7dd23e8c822933e375b7a2e7f9e57be4622ef0a12bb914154ec477473f2e31c20dfdaa6f" ++
    "5cfd53bacd98d9922100a5fdbe4d83bcbebeee008bccad30266750df8686130f3d3117d02d5993a4" ++
    "5bd9489d81f3577163e21d81bb218996db9fbea9cdd1f84efc483b00e95315b5eaa63b557644accb" ++
    "514bd8e76af329201d6c4e464b299c88928c16a9e795588406f3946b78ec22118cb0454627848e38" ++
    "601c5fd179a0af5c7a0a72776adc430203010001a3693067301d0603551d0e04160414568beea221" ++
    "4576d0043ccb7c84502520d1d1cf2d301f0603551d23041830168014568beea2214576d0043ccb7c" ++
    "84502520d1d1cf2d300f0603551d130101ff040530030101ff30140603551d11040d300b82096c6f" ++
    "63616c686f7374300d06092a864886f70d01010b05000382010100d7be5d520c71ebbdd274d06719" ++
    "ee1ae5feccb599abd6a3c46739649686900decac90f72fb5aec3fdb1ab3afec04e8e4b677cdcfac5" ++
    "78f63765a75f4a3bf827fe6c21b0f082647f017198952c290865f24e6ef7f48b415b14d32533a96f" ++
    "7f2939b1385091a1fb52b6c65ddf71886d86d38aa127241a82e64722981facab3fcf7b2c1ef91dbd" ++
    "9d1f136b8ff020d38f8d9c49a3cfe6d6e255faadf503e9fc458cb853e8a54b0b7660f295fb0dbad7" ++
    "2f24b81870e7cc574d839421648506d3c3a5f80bc32cbdc84325ddbf8ddf73e6dc54cd106905c769" ++
    "ac2b9e0ad48a2e2a743422d9b7db29189fc489ba8da82af6dce3103031083dfe2c7cb32aca3906c2" ++
    "f10824";

/// Default iteration count, override with argv[1].
const DEFAULT_ITERATIONS: usize = 1_000_000;

fn parseOnly(der: []const u8) bool {
    const cert: std.crypto.Certificate = .{
        .buffer = der,
        .index = 0,
    };
    const parsed = cert.parse() catch |err| switch (err) {
        else => return false,
    };

    return parsed.pub_key_slice.end != 0;
}

fn nanosSince(io: std.Io, start: std.Io.Timestamp) i96 {
    return start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
}

fn report(name: []const u8, label: []const u8, total_ns: i96, iterations: usize) void {
    const per_op: u64 = @intCast(@divTrunc(total_ns, @as(i96, @intCast(iterations))));

    std.debug.print("{s:<6} {s:<14} {d:>8} ns/op\n", .{
        name,
        label,
        per_op,
    });
}

fn benchOne(io: std.Io, name: []const u8, der: []const u8, iterations: usize) void {
    var sink: usize = 0;

    var start = std.Io.Clock.awake.now(io);
    for (0..iterations) |_| sink += @intFromBool(isSafeCertificate(der));
    report(name, "guard", nanosSince(io, start), iterations);

    start = std.Io.Clock.awake.now(io);
    for (0..iterations) |_| sink += @intFromBool(parseOnly(der));
    report(name, "parse", nanosSince(io, start), iterations);

    start = std.Io.Clock.awake.now(io);
    for (0..iterations) |_| {
        if (isSafeCertificate(der)) sink += @intFromBool(parseOnly(der));
    }
    report(name, "guard + parse", nanosSince(io, start), iterations);

    std.mem.doNotOptimizeAway(sink);
}

fn benchEcdsaVerify(io: std.Io, der: []const u8, iterations: usize) void {
    const cert: std.crypto.Certificate = .{
        .buffer = der,
        .index = 0,
    };
    const parsed = cert.parse() catch |err| switch (err) {
        else => return,
    };
    var sink: usize = 0;

    const start = std.Io.Clock.awake.now(io);
    for (0..iterations) |_| {
        parsed.verify(parsed, 1_800_000_000) catch |err| switch (err) {
            else => {},
        };
        sink += 1;
    }
    report("ecdsa", "verify", nanosSince(io, start), iterations);

    std.mem.doNotOptimizeAway(sink);
}

pub fn main(process: std.process.Init) !void {
    const args = try process.minimal.args.toSlice(process.arena.allocator());
    const iterations = if (args.len > 1)
        try std.fmt.parseInt(usize, args[1], 10)
    else
        DEFAULT_ITERATIONS;

    var ec_buf: [1024]u8 = undefined;
    var rsa_buf: [1024]u8 = undefined;
    const ec_der = try std.fmt.hexToBytes(&ec_buf, EC_CERT_HEX);
    const rsa_der = try std.fmt.hexToBytes(&rsa_buf, RSA_CERT_HEX);

    benchOne(process.io, "ecdsa", ec_der, iterations);
    benchOne(process.io, "rsa", rsa_der, iterations);
    benchEcdsaVerify(process.io, ec_der, @max(iterations / 1000, 1));
}
