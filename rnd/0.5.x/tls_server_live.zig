//! TLS 1.3 P0 live server: a real single-connection handshake over a TCP socket, the openssl
//! s_client interop step of P0 (tls-plan.md). This is the in-memory composition
//! driver (tls_server_poc.zig) wired onto a blocking socket with a fresh per-connection
//! ephemeral key and the real client transcript (not the RFC 8448 trace).
//!
//! Note:
//! - Flow: accept one connection, read the ClientHello, generate an X25519 ephemeral key, send
//!   ServerHello (plaintext) + a legacy ChangeCipherSpec, derive the handshake secrets from the
//!   live transcript, send the encrypted flight (EncryptedExtensions, Certificate,
//!   CertificateVerify, Finished) under the handshake key, then derive the application secrets.
//! - Receive side: read the client ChangeCipherSpec (skipped) and the client Finished, deprotect
//!   it under the client handshake key, and verify verify_data against
//!   HMAC(client finished_key, transcript through the server Finished). Then deprotect the first
//!   client application record (the request), send one application response, and send an
//!   encrypted close_notify alert before closing. This completes the full 1-RTT handshake plus a
//!   request / response, both directions of the record layer exercised.
//! - Signing is ECDSA P-256 with the fixture key, the transcript is the real bytes openssl sent,
//!   so openssl validates the ServerHello, certificate, CertificateVerify, and Finished for real.
//! - Crypto is the verified per-layer code (HKDF-Expand-Label, the key schedule, AES-128-GCM
//!   record protection, the ECDSA CertificateVerify), here driven live.
//!
//! Usage:
//! ```sh
//! zig run rnd/0.5.x/tls_server_live.zig -- 4443 &
//! echo | openssl s_client -connect 127.0.0.1:4443 -tls1_3 -servername localhost
//! ```
//!
//! Run: zig run rnd/0.5.x/tls_server_live.zig -- <port>

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const X25519 = std.crypto.dh.X25519;
const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

const hash_len = Sha256.digest_length;

const cert_der = @embedFile("tls-certs/ecdsa_p256_cert.der");
const ecdsa_private_scalar = hx("0b 76 f7 f1 c7 bf 6e 20 02 9d db 56 67 95 e5 8d a5 ba 63 ff bd b9 14 bf 69 9b fb ed 31 47 d3 2c");

const cipher_aes_128_gcm_sha256: u16 = 0x1301;
const group_x25519: u16 = 0x001d;
const sig_ecdsa_secp256r1_sha256: u16 = 0x0403;
const certificate_verify_context = "TLS 1.3, server CertificateVerify";

const content_type_change_cipher_spec: u8 = 20;
const content_type_alert: u8 = 21;
const content_type_handshake: u8 = 22;
const content_type_application_data: u8 = 23;

pub fn main() !void {
    const port: u16 = 4443;
    const listener = try listen(port);
    defer closeFd(listener);

    std.debug.print("zix tls 1.3 server listening on 127.0.0.1:{d}\n", .{port});

    const accept_rc = linux.accept4(listener, null, null, 0);
    if (posix.errno(accept_rc) != .SUCCESS) return error.AcceptFailed;
    const client: posix.fd_t = @intCast(accept_rc);
    defer closeFd(client);

    handshake(client) catch |err| {
        std.debug.print("handshake error: {s}\n", .{@errorName(err)});

        return err;
    };

    std.debug.print("handshake complete, application data sent\n", .{});
}

// --------------------------------------------------------------- //
// the handshake (RFC 8446 sec 4), driven live against the connected client.

fn handshake(fd: posix.fd_t) !void {
    var read_buf: [16640]u8 = undefined;
    var transcript = Sha256.init(.{});

    // ClientHello (plaintext handshake record).
    const client_hello = try readHandshakeRecord(fd, &read_buf);
    transcript.update(client_hello);
    const hello = try parseClientHello(client_hello);

    // server ephemeral key + ServerHello.
    var seed: [32]u8 = undefined;
    _ = linux.getrandom(&seed, seed.len, 0);
    const server_keys = try X25519.KeyPair.generateDeterministic(seed);
    var server_random: [32]u8 = undefined;
    _ = linux.getrandom(&server_random, server_random.len, 0);

    var sh_buf: [256]u8 = undefined;
    const server_hello = serializeServerHello(&sh_buf, server_random, hello.session_id, server_keys.public_key);
    try writeRecord(fd, content_type_handshake, server_hello);
    transcript.update(server_hello);

    // legacy ChangeCipherSpec (middlebox compatibility, RFC 8446 D.4).
    try writeRecord(fd, content_type_change_cipher_spec, &[_]u8{0x01});

    // handshake key schedule from the live transcript through ServerHello.
    const ecdhe = try X25519.scalarmult(server_keys.secret_key, hello.client_public);
    const empty_hash = emptyHash();
    const early_secret = HkdfSha256.extract(&zero32, &zero32);
    const derived = deriveSecret(early_secret, "derived", empty_hash);
    const handshake_secret = HkdfSha256.extract(&derived, &ecdhe);

    const transcript_ch_sh = peek(transcript);
    const server_hs_traffic = deriveSecret(handshake_secret, "s hs traffic", transcript_ch_sh);
    var hs_key: [16]u8 = undefined;
    var hs_iv: [12]u8 = undefined;
    var server_finished_key: [hash_len]u8 = undefined;
    hkdfExpandLabel(&hs_key, server_hs_traffic, "key", "");
    hkdfExpandLabel(&hs_iv, server_hs_traffic, "iv", "");
    hkdfExpandLabel(&server_finished_key, server_hs_traffic, "finished", "");

    const client_hs_traffic = deriveSecret(handshake_secret, "c hs traffic", transcript_ch_sh);
    var client_hs_key: [16]u8 = undefined;
    var client_hs_iv: [12]u8 = undefined;
    var client_finished_key: [hash_len]u8 = undefined;
    hkdfExpandLabel(&client_hs_key, client_hs_traffic, "key", "");
    hkdfExpandLabel(&client_hs_iv, client_hs_traffic, "iv", "");
    hkdfExpandLabel(&client_finished_key, client_hs_traffic, "finished", "");

    // build the encrypted flight: EncryptedExtensions, Certificate, CertificateVerify, Finished.
    var flight_buf: [4096]u8 = undefined;
    var fw = Writer{ .buf = &flight_buf };

    const ee = buildEncryptedExtensions(fw.tail());
    fw.advance(ee.len);
    transcript.update(ee);

    const cert_msg = buildCertificateMessage(fw.tail());
    fw.advance(cert_msg.len);
    transcript.update(cert_msg);

    const key_pair = try EcdsaP256.KeyPair.fromSecretKey(try EcdsaP256.SecretKey.fromBytes(ecdsa_private_scalar));
    const cert_verify = try buildCertificateVerify(fw.tail(), key_pair, peek(transcript));
    fw.advance(cert_verify.len);
    transcript.update(cert_verify);

    const finished = buildFinished(fw.tail(), server_finished_key, peek(transcript));
    fw.advance(finished.len);
    transcript.update(finished);

    try sendEncrypted(fd, hs_key, hs_iv, 0, fw.slice(), content_type_handshake);

    // application key schedule from the transcript through the server Finished.
    const transcript_server_finished = peek(transcript);
    const derived_master = deriveSecret(handshake_secret, "derived", empty_hash);
    const master_secret = HkdfSha256.extract(&derived_master, &zero32);
    const server_ap_traffic = deriveSecret(master_secret, "s ap traffic", transcript_server_finished);
    const client_ap_traffic = deriveSecret(master_secret, "c ap traffic", transcript_server_finished);
    var ap_key: [16]u8 = undefined;
    var ap_iv: [12]u8 = undefined;
    var client_ap_key: [16]u8 = undefined;
    var client_ap_iv: [12]u8 = undefined;
    hkdfExpandLabel(&ap_key, server_ap_traffic, "key", "");
    hkdfExpandLabel(&ap_iv, server_ap_traffic, "iv", "");
    hkdfExpandLabel(&client_ap_key, client_ap_traffic, "key", "");
    hkdfExpandLabel(&client_ap_iv, client_ap_traffic, "iv", "");

    // receive side: read + verify the client Finished, then read the client request.
    var expected_client_finished: [hash_len]u8 = undefined;
    HmacSha256.create(&expected_client_finished, &transcript_server_finished, &client_finished_key);
    try readClientFinished(fd, client_hs_key, client_hs_iv, expected_client_finished);
    std.debug.print("client Finished verified\n", .{});

    var request_buf: [16640]u8 = undefined;
    const request = try readApplicationData(fd, &request_buf, client_ap_key, client_ap_iv);
    std.debug.print("client request ({d} bytes): \"{s}\"\n", .{ request.len, trimForLog(request) });

    // respond under the application key, then a close_notify alert (seq 1).
    try sendEncrypted(fd, ap_key, ap_iv, 0, "zix-tls-ok\n", content_type_application_data);
    try sendEncrypted(fd, ap_key, ap_iv, 1, &[_]u8{ 1, 0 }, content_type_alert);
}

// --------------------------------------------------------------- //
// receive side: read + deprotect inbound records (client Finished, then application data).

fn readClientFinished(fd: posix.fd_t, key: [16]u8, iv: [12]u8, expected: [hash_len]u8) !void {
    var record_buf: [16640]u8 = undefined;
    var plain_buf: [16640]u8 = undefined;

    while (true) {
        const record = try recvRecord(fd, &record_buf);
        if (record.content_type == content_type_change_cipher_spec) continue; // legacy compat, skip

        if (record.content_type != content_type_application_data) return error.UnexpectedRecord;

        const inner = try deprotectRecord(&plain_buf, record.bytes, key, iv, 0);
        if (inner.inner_type != content_type_handshake) return error.UnexpectedRecord;
        if (inner.data.len < 4 + hash_len) return error.BadFinished;

        const verify_data = inner.data[4 .. 4 + hash_len];
        if (!std.mem.eql(u8, verify_data, &expected)) return error.ClientFinishedMismatch;

        return;
    }
}

fn readApplicationData(fd: posix.fd_t, buf: []u8, key: [16]u8, iv: [12]u8) ![]const u8 {
    var record_buf: [16640]u8 = undefined;

    while (true) {
        const record = try recvRecord(fd, &record_buf);
        if (record.content_type == content_type_change_cipher_spec) continue;

        if (record.content_type != content_type_application_data) return error.UnexpectedRecord;

        const inner = try deprotectRecord(buf, record.bytes, key, iv, 0);
        if (inner.inner_type == content_type_alert) return buf[0..0]; // client closed without a request

        if (inner.inner_type != content_type_application_data) return error.UnexpectedRecord;

        return inner.data;
    }
}

const Record = struct {
    content_type: u8,
    bytes: []const u8,
};

fn recvRecord(fd: posix.fd_t, buf: []u8) !Record {
    try readAll(fd, buf[0..5]);

    const length = std.mem.readInt(u16, buf[3..5], .big);
    if (5 + length > buf.len) return error.Truncated;

    try readAll(fd, buf[5 .. 5 + length]);

    return .{ .content_type = buf[0], .bytes = buf[0 .. 5 + length] };
}

const Inner = struct {
    inner_type: u8,
    data: []const u8,
};

fn deprotectRecord(out: []u8, record: []const u8, key: [16]u8, iv: [12]u8, seq: u64) !Inner {
    const header = record[0..5];
    const body = record[5..];
    if (body.len < Aes128Gcm.tag_length) return error.BadRecord;

    const cipher = body[0 .. body.len - Aes128Gcm.tag_length];
    var tag: [Aes128Gcm.tag_length]u8 = undefined;
    @memcpy(&tag, body[body.len - Aes128Gcm.tag_length ..]);

    const plaintext = out[0..cipher.len];
    try Aes128Gcm.decrypt(plaintext, cipher, tag, header, nonceFor(iv, seq), key);

    // TLS 1.3 inner plaintext is content || content_type || zero-padding, the type is the last
    // non-zero octet (RFC 8446 5.2, 5.4).
    var end = plaintext.len;
    while (end > 0 and plaintext[end - 1] == 0) end -= 1;
    if (end == 0) return error.BadRecord;

    return .{ .inner_type = plaintext[end - 1], .data = plaintext[0 .. end - 1] };
}

fn trimForLog(bytes: []const u8) []const u8 {
    var end = bytes.len;
    while (end > 0 and (bytes[end - 1] == '\n' or bytes[end - 1] == '\r')) end -= 1;

    return bytes[0..end];
}

// --------------------------------------------------------------- //
// ClientHello parse (only the fields the server needs).

const ClientHello = struct {
    session_id: []const u8,
    client_public: [32]u8,
};

fn parseClientHello(bytes: []const u8) !ClientHello {
    var r = Reader{ .buf = bytes };

    if (try r.readU8() != 1) return error.Truncated;
    _ = try r.readU24();
    _ = try r.readU16(); // legacy_version
    _ = try r.readBytes(32); // random
    const session_id_len = try r.readU8();
    const session_id = try r.readBytes(session_id_len);
    const cipher_suites_len = try r.readU16();
    _ = try r.readBytes(cipher_suites_len);
    const compression_len = try r.readU8();
    _ = try r.readBytes(compression_len);

    var offers_tls13 = false;
    var client_public: ?[]const u8 = null;

    const extensions_len = try r.readU16();
    const extensions = try r.readBytes(extensions_len);
    var er = Reader{ .buf = extensions };
    while (er.remaining() >= 4) {
        const ext_type = try er.readU16();
        const ext_len = try er.readU16();
        const ext_data = try er.readBytes(ext_len);

        switch (ext_type) {
            0x002b => { // supported_versions
                var vr = Reader{ .buf = ext_data };
                const list_len = try vr.readU8();
                const list = try vr.readBytes(list_len);
                var lr = Reader{ .buf = list };
                while (lr.remaining() >= 2) {
                    if (try lr.readU16() == 0x0304) offers_tls13 = true;
                }
            },
            0x0033 => { // key_share
                var kr = Reader{ .buf = ext_data };
                const shares_len = try kr.readU16();
                const shares = try kr.readBytes(shares_len);
                var sr = Reader{ .buf = shares };
                while (sr.remaining() >= 4) {
                    const group = try sr.readU16();
                    const ke_len = try sr.readU16();
                    const ke = try sr.readBytes(ke_len);
                    if (group == group_x25519 and ke.len == 32) client_public = ke;
                }
            },
            else => {},
        }
    }

    if (!offers_tls13) return error.NoTls13;
    const pub_slice = client_public orelse return error.NoX25519;

    var ch = ClientHello{ .session_id = session_id, .client_public = undefined };
    @memcpy(&ch.client_public, pub_slice);

    return ch;
}

// --------------------------------------------------------------- //
// message builders (reused from the composition driver).

fn serializeServerHello(buf: []u8, random: [32]u8, session_id: []const u8, public_key: [32]u8) []const u8 {
    var w = Writer{ .buf = buf };

    w.writeU8(2);
    const header = w.placeU24();
    w.writeU16(0x0303);
    w.writeBytes(&random);
    w.writeU8(@intCast(session_id.len));
    w.writeBytes(session_id);
    w.writeU16(cipher_aes_128_gcm_sha256);
    w.writeU8(0);

    const extensions = w.placeU16();
    w.writeU16(0x0033); // key_share
    const key_share = w.placeU16();
    w.writeU16(group_x25519);
    const key_exchange = w.placeU16();
    w.writeBytes(&public_key);
    w.patchU16(key_exchange);
    w.patchU16(key_share);
    w.writeU16(0x002b); // supported_versions
    const supported_versions = w.placeU16();
    w.writeU16(0x0304);
    w.patchU16(supported_versions);
    w.patchU16(extensions);

    w.patchU24(header);

    return w.slice();
}

fn buildEncryptedExtensions(buf: []u8) []const u8 {
    var w = Writer{ .buf = buf };

    w.writeU8(8);
    const header = w.placeU24();
    w.writeU16(0); // no extensions
    w.patchU24(header);

    return w.slice();
}

fn buildCertificateMessage(buf: []u8) []const u8 {
    var w = Writer{ .buf = buf };

    w.writeU8(11);
    const header = w.placeU24();
    w.writeU8(0); // empty certificate_request_context

    const list = w.placeU24();
    const entry = w.placeU24();
    w.writeBytes(cert_der);
    w.patchU24(entry);
    w.writeU16(0); // empty entry extensions
    w.patchU24(list);

    w.patchU24(header);

    return w.slice();
}

fn buildCertificateVerify(buf: []u8, key_pair: EcdsaP256.KeyPair, transcript_hash: [hash_len]u8) ![]const u8 {
    var content: [64 + certificate_verify_context.len + 1 + hash_len]u8 = undefined;
    @memset(content[0..64], 0x20);
    @memcpy(content[64 .. 64 + certificate_verify_context.len], certificate_verify_context);
    content[64 + certificate_verify_context.len] = 0x00;
    @memcpy(content[64 + certificate_verify_context.len + 1 ..], &transcript_hash);

    const signature = try key_pair.sign(&content, null);
    var der_buf: [EcdsaP256.Signature.der_encoded_length_max]u8 = undefined;
    const der = signature.toDer(&der_buf);

    var w = Writer{ .buf = buf };
    w.writeU8(15);
    const header = w.placeU24();
    w.writeU16(sig_ecdsa_secp256r1_sha256);
    const sig = w.placeU16();
    w.writeBytes(der);
    w.patchU16(sig);
    w.patchU24(header);

    return w.slice();
}

fn buildFinished(buf: []u8, finished_key: [hash_len]u8, transcript_hash: [hash_len]u8) []const u8 {
    var verify_data: [hash_len]u8 = undefined;
    HmacSha256.create(&verify_data, &transcript_hash, &finished_key);

    var w = Writer{ .buf = buf };
    w.writeU8(20);
    const header = w.placeU24();
    w.writeBytes(&verify_data);
    w.patchU24(header);

    return w.slice();
}

// --------------------------------------------------------------- //
// record layer + socket I/O.

fn writeRecord(fd: posix.fd_t, content_type: u8, payload: []const u8) !void {
    var header: [5]u8 = undefined;
    header[0] = content_type;
    header[1] = 0x03;
    header[2] = 0x03;
    std.mem.writeInt(u16, header[3..5], @intCast(payload.len), .big);

    try writeAll(fd, &header);
    try writeAll(fd, payload);
}

fn sendEncrypted(fd: posix.fd_t, key: [16]u8, iv: [12]u8, seq: u64, inner: []const u8, inner_type: u8) !void {
    var record: [16640]u8 = undefined;

    const inner_len = inner.len + 1;
    const record_len = inner_len + Aes128Gcm.tag_length;

    record[0] = content_type_application_data;
    record[1] = 0x03;
    record[2] = 0x03;
    std.mem.writeInt(u16, record[3..5], @intCast(record_len), .big);

    var plaintext: [16640]u8 = undefined;
    @memcpy(plaintext[0..inner.len], inner);
    plaintext[inner.len] = inner_type;

    const cipher = record[5 .. 5 + inner_len];
    var tag: [Aes128Gcm.tag_length]u8 = undefined;
    Aes128Gcm.encrypt(cipher, &tag, plaintext[0..inner_len], record[0..5], nonceFor(iv, seq), key);
    @memcpy(record[5 + inner_len .. 5 + inner_len + Aes128Gcm.tag_length], &tag);

    try writeAll(fd, record[0 .. 5 + record_len]);
}

/// Read one plaintext handshake record body (the ClientHello arrives as a single record).
fn readHandshakeRecord(fd: posix.fd_t, buf: []u8) ![]const u8 {
    var header: [5]u8 = undefined;
    try readAll(fd, &header);

    const length = std.mem.readInt(u16, header[3..5], .big);
    if (length > buf.len) return error.Truncated;

    const body = buf[0..length];
    try readAll(fd, body);

    return body;
}

fn nonceFor(iv: [12]u8, seq: u64) [12]u8 {
    var nonce = iv;
    var seq_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &seq_bytes, seq, .big);

    var i: usize = 0;
    while (i < 8) : (i += 1) nonce[4 + i] ^= seq_bytes[i];

    return nonce;
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const chunk = bytes[written..];
        const rc = linux.write(fd, chunk.ptr, chunk.len);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.WriteFailed,
        }
        written += rc;
    }
}

fn readAll(fd: posix.fd_t, buf: []u8) !void {
    var read: usize = 0;
    while (read < buf.len) {
        const chunk = buf[read..];
        const rc = linux.read(fd, chunk.ptr, chunk.len);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ReadFailed,
        }
        if (rc == 0) return error.Truncated;
        read += rc;
    }
}

fn listen(port: u16) !posix.fd_t {
    const socket_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    if (posix.errno(socket_rc) != .SUCCESS) return error.SocketFailed;
    const fd: posix.fd_t = @intCast(socket_rc);

    const one: c_int = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&one), @sizeOf(c_int));

    var addr = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7f000001), // 127.0.0.1
    };
    const addr_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    if (posix.errno(linux.bind(fd, @ptrCast(&addr), addr_len)) != .SUCCESS) return error.BindFailed;
    if (posix.errno(linux.listen(fd, 1)) != .SUCCESS) return error.ListenFailed;

    return fd;
}

fn closeFd(fd: posix.fd_t) void {
    _ = linux.close(fd);
}

// --------------------------------------------------------------- //
// key schedule glue (Layer K).

const zero32 = std.mem.zeroes([hash_len]u8);

fn emptyHash() [hash_len]u8 {
    var sha = Sha256.init(.{});

    return sha.finalResult();
}

fn peek(transcript: Sha256) [hash_len]u8 {
    var copy = transcript;

    return copy.finalResult();
}

fn hkdfExpandLabel(out: []u8, secret: [hash_len]u8, label: []const u8, context: []const u8) void {
    const prefix = "tls13 ";

    var info: [2 + 1 + prefix.len + 255 + 1 + hash_len]u8 = undefined;
    std.mem.writeInt(u16, info[0..2], @intCast(out.len), .big);
    info[2] = @intCast(prefix.len + label.len);
    @memcpy(info[3 .. 3 + prefix.len], prefix);
    @memcpy(info[3 + prefix.len .. 3 + prefix.len + label.len], label);

    const ctx_len_pos = 3 + prefix.len + label.len;
    info[ctx_len_pos] = @intCast(context.len);
    @memcpy(info[ctx_len_pos + 1 .. ctx_len_pos + 1 + context.len], context);

    HkdfSha256.expand(out, info[0 .. ctx_len_pos + 1 + context.len], secret);
}

fn deriveSecret(secret: [hash_len]u8, label: []const u8, transcript_hash: [hash_len]u8) [hash_len]u8 {
    var out: [hash_len]u8 = undefined;
    hkdfExpandLabel(&out, secret, label, &transcript_hash);

    return out;
}

// --------------------------------------------------------------- //
// reader / writer / hex.

const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn readU8(self: *Reader) error{Truncated}!u8 {
        if (self.pos + 1 > self.buf.len) return error.Truncated;

        const value = self.buf[self.pos];
        self.pos += 1;

        return value;
    }

    fn readU16(self: *Reader) error{Truncated}!u16 {
        if (self.pos + 2 > self.buf.len) return error.Truncated;

        const value = std.mem.readInt(u16, self.buf[self.pos..][0..2], .big);
        self.pos += 2;

        return value;
    }

    fn readU24(self: *Reader) error{Truncated}!u32 {
        if (self.pos + 3 > self.buf.len) return error.Truncated;

        const b = self.buf[self.pos..][0..3];
        self.pos += 3;

        return (@as(u32, b[0]) << 16) | (@as(u32, b[1]) << 8) | b[2];
    }

    fn readBytes(self: *Reader, n: usize) error{Truncated}![]const u8 {
        if (self.pos + n > self.buf.len) return error.Truncated;

        const slice = self.buf[self.pos .. self.pos + n];
        self.pos += n;

        return slice;
    }

    fn remaining(self: *const Reader) usize {
        return self.buf.len - self.pos;
    }
};

const Writer = struct {
    buf: []u8,
    len: usize = 0,

    fn writeU8(self: *Writer, value: u8) void {
        self.buf[self.len] = value;
        self.len += 1;
    }

    fn writeU16(self: *Writer, value: u16) void {
        std.mem.writeInt(u16, self.buf[self.len..][0..2], value, .big);
        self.len += 2;
    }

    fn writeU24(self: *Writer, value: u32) void {
        self.buf[self.len] = @intCast((value >> 16) & 0xff);
        self.buf[self.len + 1] = @intCast((value >> 8) & 0xff);
        self.buf[self.len + 2] = @intCast(value & 0xff);
        self.len += 3;
    }

    fn writeBytes(self: *Writer, bytes: []const u8) void {
        @memcpy(self.buf[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    fn placeU16(self: *Writer) usize {
        const marker = self.len;
        self.writeU16(0);

        return marker;
    }

    fn patchU16(self: *Writer, marker: usize) void {
        std.mem.writeInt(u16, self.buf[marker..][0..2], @intCast(self.len - marker - 2), .big);
    }

    fn placeU24(self: *Writer) usize {
        const marker = self.len;
        self.writeU24(0);

        return marker;
    }

    fn patchU24(self: *Writer, marker: usize) void {
        const value: u32 = @intCast(self.len - marker - 3);
        self.buf[marker] = @intCast((value >> 16) & 0xff);
        self.buf[marker + 1] = @intCast((value >> 8) & 0xff);
        self.buf[marker + 2] = @intCast(value & 0xff);
    }

    fn slice(self: *const Writer) []const u8 {
        return self.buf[0..self.len];
    }

    fn tail(self: *Writer) []u8 {
        return self.buf[self.len..];
    }

    fn advance(self: *Writer, n: usize) void {
        self.len += n;
    }
};

fn hexLen(comptime s: []const u8) usize {
    @setEvalBranchQuota(200000);
    var n: usize = 0;
    for (s) |c| switch (c) {
        '0'...'9', 'a'...'f', 'A'...'F' => n += 1,
        else => {},
    };

    return n / 2;
}

fn hx(comptime s: []const u8) [hexLen(s)]u8 {
    @setEvalBranchQuota(200000);
    var out: [hexLen(s)]u8 = undefined;
    var oi: usize = 0;
    var high: ?u8 = null;
    for (s) |c| {
        const nibble: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => continue,
        };
        if (high) |h| {
            out[oi] = (h << 4) | nibble;
            oi += 1;
            high = null;
        } else {
            high = nibble;
        }
    }

    return out;
}
