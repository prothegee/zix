//! Minimal hand-rolled HTTP/3 (QUIC over TLS 1.3) client for the test runners.
//!
//! What:
//! - zix ships an HTTP/3 server but no QUIC client, so this drives the peer side of the wire from the
//!   exported zix.Http3 primitives (crypto / protection / keyschedule / qpack / packet / varint /
//!   frame) plus the TLS 1.3 handshake bytes. This mirrors how the HTTP/2 runner hand-rolls a client
//!   from zix.Http2 frame and HPACK primitives.
//! - It performs one full round trip: send Initial(ClientHello), receive ServerHello + the server
//!   Handshake flight, derive the handshake then 1-RTT keys, send the request on stream 0, and return
//!   the decrypted response body. It is built against THIS server: the server ignores client
//!   transport parameters and only needs :method + :path, so the ClientHello and request are minimal.

const std = @import("std");
const zix = @import("zix");

const h3 = zix.Http3;
const crypto = h3.crypto;
const protection = h3.protection;
const keyschedule = h3.keyschedule;
const qpack = h3.qpack;
const packet = h3.packet;
const varint = h3.varint;
const ks = h3.tls_key_schedule;
const X25519 = std.crypto.dh.X25519;

const BIND_PORT: u16 = 9195;
const CID_LEN: usize = 8;
const INITIAL_MIN: usize = 1162; // pad the client Initial payload so the packet clears QUIC's 1200 floor.

// --------------------------------------------------------- //

/// A tiny big-endian TLS writer: enough to serialize a ClientHello by hand (the TLS layer has no
/// public ClientHello builder that carries no transport params).
const Writer = struct {
    buf: []u8,
    pos: usize = 0,

    fn u8v(self: *Writer, value: u8) void {
        self.buf[self.pos] = value;
        self.pos += 1;
    }

    fn u16v(self: *Writer, value: u16) void {
        std.mem.writeInt(u16, self.buf[self.pos..][0..2], value, .big);
        self.pos += 2;
    }

    fn bytes(self: *Writer, data: []const u8) void {
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    /// Reserve a u16 length slot, returning its offset for a later patch.
    fn placeU16(self: *Writer) usize {
        const at = self.pos;
        self.pos += 2;

        return at;
    }

    /// Back-patch a u16 length slot with the bytes written since it was reserved.
    fn patchU16(self: *Writer, at: usize) void {
        std.mem.writeInt(u16, self.buf[at..][0..2], @intCast(self.pos - at - 2), .big);
    }

    /// Reserve a u24 length slot (the TLS handshake message length), returning its offset.
    fn placeU24(self: *Writer) usize {
        const at = self.pos;
        self.pos += 3;

        return at;
    }

    /// Back-patch a u24 length slot with the bytes written since it was reserved.
    fn patchU24(self: *Writer, at: usize) void {
        const len: u24 = @intCast(self.pos - at - 3);
        self.buf[at] = @intCast(len >> 16);
        self.buf[at + 1] = @intCast((len >> 8) & 0xff);
        self.buf[at + 2] = @intCast(len & 0xff);
    }
};

/// Serialize a minimal TLS 1.3 ClientHello (RFC 8446 4.1.2) offering AES_128_GCM_SHA256, X25519, and
/// ECDSA-P256 signatures, with our X25519 key share. No quic_transport_parameters extension: this
/// server ignores it.
fn buildClientHello(buf: []u8, client_random: [32]u8, x25519_pub: [32]u8) []const u8 {
    var w = Writer{ .buf = buf };

    w.u8v(0x01); // CLIENT_HELLO
    const body = w.placeU24(); // handshake message length

    w.u16v(0x0303); // legacy_version TLS 1.2
    w.bytes(&client_random);
    w.u8v(0x00); // empty session_id

    w.u16v(0x0002); // cipher_suites length
    w.u16v(0x1301); // TLS_AES_128_GCM_SHA256

    w.u8v(0x01); // compression methods length
    w.u8v(0x00); // null compression

    const exts = w.placeU16();

    w.u16v(0x002b); // supported_versions
    const sv = w.placeU16();
    w.u8v(0x02); // list length
    w.u16v(0x0304); // TLS 1.3
    w.patchU16(sv);

    w.u16v(0x000a); // supported_groups
    const sg = w.placeU16();
    w.u16v(0x0002); // list length
    w.u16v(0x001d); // X25519
    w.patchU16(sg);

    w.u16v(0x000d); // signature_algorithms
    const sa = w.placeU16();
    w.u16v(0x0002); // list length
    w.u16v(0x0403); // ECDSA_SECP256R1_SHA256
    w.patchU16(sa);

    w.u16v(0x0033); // key_share
    const kshare = w.placeU16();
    w.u16v(0x0024); // client_shares length (2 + 2 + 32)
    w.u16v(0x001d); // X25519
    w.u16v(0x0020); // key_exchange length 32
    w.bytes(&x25519_pub);
    w.patchU16(kshare);

    w.patchU16(exts);
    w.patchU24(body);

    return w.buf[0..w.pos];
}

/// Parse a ServerHello's X25519 key_share value (RFC 8446 4.1.3). The layout is fixed by
/// serializeServerHello: KEY_SHARE is the first extension.
fn serverKeyShare(server_hello: []const u8) ?[32]u8 {
    // type(1) + len(3) + version(2) + random(32) + session_id_len(1) ...
    var pos: usize = 4 + 2 + 32;
    if (pos >= server_hello.len) return null;

    const session_id_len = server_hello[pos];
    pos += 1 + session_id_len;
    pos += 2 + 1; // cipher_suite(2) + compression(1)
    if (pos + 2 > server_hello.len) return null;

    pos += 2; // extensions length
    while (pos + 4 <= server_hello.len) {
        const ext_type = std.mem.readInt(u16, server_hello[pos..][0..2], .big);
        const ext_len = std.mem.readInt(u16, server_hello[pos + 2 ..][0..2], .big);
        pos += 4;
        if (pos + ext_len > server_hello.len) return null;

        if (ext_type == 0x0033) {
            // KEY_SHARE: group(2) + key_exchange_len(2) + key_exchange.
            if (ext_len < 4) return null;
            const ke_len = std.mem.readInt(u16, server_hello[pos + 2 ..][0..2], .big);
            if (ke_len != 32 or pos + 4 + 32 > server_hello.len) return null;

            var out: [32]u8 = undefined;
            @memcpy(&out, server_hello[pos + 4 ..][0..32]);

            return out;
        }

        pos += ext_len;
    }

    return null;
}

/// Return the data of the first CRYPTO frame in a decrypted Initial / Handshake payload. The server
/// seals exactly one CRYPTO frame (the ServerHello, or the EE+Cert+CertVerify+Finished flight) per
/// packet, so this is the whole TLS message stream at that level.
fn firstCryptoData(payload: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < payload.len) {
        const ftype = varint.read(payload[pos..]) catch return null;
        pos += ftype.len;

        switch (ftype.value) {
            0x00, 0x01 => {}, // PADDING, PING
            0x06 => {
                const offset = varint.read(payload[pos..]) catch return null;
                pos += offset.len;
                const length = varint.read(payload[pos..]) catch return null;
                pos += length.len;
                const len: usize = @intCast(length.value);
                if (pos + len > payload.len) return null;

                return payload[pos .. pos + len];
            },
            else => return null,
        }
    }

    return null;
}

/// Walk a decrypted 1-RTT payload, find the STREAM frame on the request stream (client bidi, id&3==0),
/// and return its HTTP/3 DATA-frame body. Skips the ACK / HANDSHAKE_DONE / control-stream frames the
/// server leads with.
fn responseBody(payload: []const u8, out: []u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < payload.len) {
        const ftype = varint.read(payload[pos..]) catch return null;
        pos += ftype.len;

        switch (ftype.value) {
            0x00, 0x01, 0x1e => {}, // PADDING, PING, HANDSHAKE_DONE
            0x02, 0x03 => { // ACK
                pos = skipAck(payload, pos, ftype.value == 0x03) orelse return null;
            },
            0x08...0x0f => {
                const parsed = parseStream(payload[pos - ftype.len ..]) orelse return null;
                if (parsed.id & 0x03 == 0) {
                    if (httpDataBody(parsed.data, out)) |body| return body;
                }

                pos = (pos - ftype.len) + parsed.consumed;
            },
            else => return null,
        }
    }

    return null;
}

const ParsedStream = struct { id: u64, data: []const u8, consumed: usize };

/// Parse one STREAM frame (RFC 9000 19.8) at the start of `buf`.
fn parseStream(buf: []const u8) ?ParsedStream {
    const frame_type = buf[0];
    var pos: usize = 1;

    const id = varint.read(buf[pos..]) catch return null;
    pos += id.len;

    if (frame_type & 0x04 != 0) {
        const offset = varint.read(buf[pos..]) catch return null;
        pos += offset.len;
    }

    const length: usize = if (frame_type & 0x02 != 0) blk: {
        const len = varint.read(buf[pos..]) catch return null;
        pos += len.len;
        break :blk @intCast(len.value);
    } else buf.len - pos;
    if (pos + length > buf.len) return null;

    return .{ .id = id.value, .data = buf[pos .. pos + length], .consumed = pos + length };
}

/// Walk the HTTP/3 frames of a request-stream payload and copy the first DATA frame's body into out.
fn httpDataBody(stream_data: []const u8, out: []u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < stream_data.len) {
        const ftype = varint.read(stream_data[pos..]) catch return null;
        pos += ftype.len;
        const length = varint.read(stream_data[pos..]) catch return null;
        pos += length.len;

        const len: usize = @intCast(length.value);
        if (pos + len > stream_data.len) return null;

        if (ftype.value == 0x00) { // DATA
            if (len > out.len) return null;
            @memcpy(out[0..len], stream_data[pos .. pos + len]);

            return out[0..len];
        }

        pos += len;
    }

    return null;
}

/// Skip an ACK frame's body, returning the position after it.
fn skipAck(buf: []const u8, start: usize, ecn: bool) ?usize {
    var pos = start;
    var i: usize = 0;
    const fixed: usize = 4; // Largest, Delay, Range Count, First Range
    while (i < fixed) : (i += 1) {
        const v = varint.read(buf[pos..]) catch return null;
        pos += v.len;
    }
    if (ecn) {
        var e: usize = 0;
        while (e < 3) : (e += 1) {
            const v = varint.read(buf[pos..]) catch return null;
            pos += v.len;
        }
    }

    return pos;
}

// --------------------------------------------------------- //

/// The 1-RTT keys and the server's Source Connection ID, the result of a completed handshake.
const Connected = struct {
    app_keys: keyschedule.AppKeys,
    server_scid: [20]u8,
    server_scid_len: usize,

    fn scid(self: *const Connected) []const u8 {
        return self.server_scid[0..self.server_scid_len];
    }
};

/// Run the QUIC + TLS 1.3 handshake on a bound socket: send Initial(ClientHello), receive ServerHello
/// then the server Handshake flight, and derive the handshake then 1-RTT keys.
fn connect(io: std.Io, sock: anytype, server: *const std.Io.net.IpAddress, dcid: []const u8, scid: []const u8, client_random: [32]u8, ephemeral: [32]u8) !Connected {
    const x25519_pub = X25519.recoverPublicKey(ephemeral) catch return error.X25519;

    const secrets = crypto.initialSecrets(dcid);
    const initial_client = crypto.AesKeys.fromSecret(secrets.client);
    const initial_server = crypto.AesKeys.fromSecret(secrets.server);

    var ch_buf: [512]u8 = undefined;
    const client_hello = buildClientHello(&ch_buf, client_random, x25519_pub);

    var transcript = ks.Transcript.init();
    transcript.update(client_hello);

    // Initial payload: a CRYPTO frame carrying the ClientHello, padded over the 1200-byte floor.
    var init_payload: [1500]u8 = undefined;
    var pp: usize = 0;
    init_payload[pp] = 0x06; // CRYPTO
    pp += 1;
    pp += varint.write(init_payload[pp..], 0); // offset
    pp += varint.write(init_payload[pp..], client_hello.len);
    @memcpy(init_payload[pp..][0..client_hello.len], client_hello);
    pp += client_hello.len;
    while (pp < INITIAL_MIN) : (pp += 1) init_payload[pp] = 0x00; // PADDING

    var initial_pkt: [1600]u8 = undefined;
    const initial = try protection.sealInitial(&initial_pkt, initial_client, dcid, scid, 0, init_payload[0..pp]);
    try sock.send(io, server, initial);

    // Receive ServerHello (Initial) then the Handshake flight, deriving keys as each arrives.
    var hs_keys: keyschedule.HandshakeKeys = undefined;
    var result = Connected{ .app_keys = undefined, .server_scid = undefined, .server_scid_len = 0 };
    var have_sh = false;
    var have_app = false;

    var attempts: usize = 0;
    while ((!have_sh or !have_app) and attempts < 16) : (attempts += 1) {
        var rbuf: [2048]u8 = undefined;
        const msg = sock.receiveTimeout(io, &rbuf, recvTimeout()) catch break;
        const data = msg.data;
        if (data.len == 0 or data[0] & 0x80 == 0) continue;

        const hdr = packet.parseLongHeader(data) catch continue;

        if (hdr.packet_type == 0 and !have_sh) {
            var obuf: [2048]u8 = undefined;
            const opened = protection.openInitial(data, initial_server, &obuf) catch continue;
            const sh = firstCryptoData(opened.payload) orelse continue;

            transcript.update(sh);
            const server_pub = serverKeyShare(sh) orelse return error.NoServerKeyShare;
            const shared = X25519.scalarmult(ephemeral, server_pub) catch return error.X25519;
            hs_keys = keyschedule.handshakeKeys(shared, transcript.current());

            @memcpy(result.server_scid[0..hdr.scid.len], hdr.scid);
            result.server_scid_len = hdr.scid.len;
            have_sh = true;
        } else if (hdr.packet_type == 2 and have_sh and !have_app) {
            var obuf: [2048]u8 = undefined;
            const opened = protection.openHandshake(data, hs_keys.server, &obuf) catch continue;
            const flight = firstCryptoData(opened.payload) orelse continue;

            transcript.update(flight);
            result.app_keys = keyschedule.applicationKeys(hs_keys.handshake_secret, transcript.current());
            have_app = true;
        }
    }

    if (!have_app) return error.HandshakeIncomplete;

    return result;
}

/// Seal a 1-RTT request packet: an HTTP/3 HEADERS frame (QPACK :method GET + :path literal) on
/// `stream_id`, sealed under the client 1-RTT keys with `client_pn`. The returned slice points into
/// `pkt_buf`, which the caller owns.
fn buildRequest(app_keys: keyschedule.AppKeys, server_scid: []const u8, stream_id: u64, client_pn: u32, path: []const u8, pkt_buf: []u8) ![]const u8 {
    var fields: [256]u8 = undefined;
    var fl: usize = 0;
    fields[0] = 0x00; // Required Insert Count 0
    fields[1] = 0x00; // Base 0
    fl = 2;
    fl += qpack.encodeStaticIndexedFieldLine(fields[fl..], 17); // :method GET
    fl += qpack.encodePrefixedInt(fields[fl..], 4, 0x50, 1); // :path literal, static name index 1
    fl += qpack.encodePrefixedInt(fields[fl..], 7, 0x00, path.len); // value length, non-Huffman
    @memcpy(fields[fl..][0..path.len], path);
    fl += path.len;

    var content: [512]u8 = undefined;
    var cl: usize = 0;
    content[0] = 0x01; // HEADERS frame
    cl = 1;
    cl += varint.write(content[cl..], fl);
    @memcpy(content[cl..][0..fl], fields[0..fl]);
    cl += fl;

    var req_payload: [1024]u8 = undefined;
    var rp: usize = 0;
    req_payload[0] = 0x0b; // STREAM | LEN | FIN
    rp = 1;
    rp += varint.write(req_payload[rp..], stream_id);
    rp += varint.write(req_payload[rp..], cl); // data length
    @memcpy(req_payload[rp..][0..cl], content[0..cl]);
    rp += cl;

    return try protection.sealShort(pkt_buf, app_keys.client, server_scid, client_pn, req_payload[0..rp]);
}

/// Receive and decrypt 1-RTT packets until one carries a request-stream body, returning it. Bare ACK /
/// control packets the server may interleave are skipped.
fn recvBody(io: std.Io, sock: anytype, app_keys: keyschedule.AppKeys, body_out: []u8) ![]const u8 {
    var attempts: usize = 0;
    while (attempts < 16) : (attempts += 1) {
        var rbuf: [2048]u8 = undefined;
        const msg = sock.receiveTimeout(io, &rbuf, recvTimeout()) catch break;
        const data = msg.data;
        if (data.len == 0 or data[0] & 0x80 != 0) continue;

        var obuf: [2048]u8 = undefined;
        const opened = protection.openShort(data, app_keys.server, CID_LEN, &obuf) catch continue;
        if (responseBody(opened.payload, body_out)) |body| return body;
    }

    return error.NoResponse;
}

/// Do one HTTP/3 GET round trip against a local QUIC server, returning the decrypted response body.
///
/// Param:
/// io - std.Io
/// server_ip - []const u8 (the server address, e.g. 127.0.0.1)
/// server_port - u16
/// path - []const u8 (the request :path, sent as a non-Huffman literal)
/// body_out - []u8 (scratch the returned body slice points into)
///
/// Return:
/// - the response body (slice into body_out)
/// - an error if any handshake or framing step fails
pub fn fetch(io: std.Io, server_ip: []const u8, server_port: u16, path: []const u8, body_out: []u8) ![]const u8 {
    var rnd: [16 + 16 + 32 + 32]u8 = undefined;
    _ = std.os.linux.getrandom(&rnd, rnd.len, 0);
    const dcid = rnd[0..CID_LEN];
    const scid = rnd[16 .. 16 + CID_LEN];
    const client_random: [32]u8 = rnd[32..64].*;
    const ephemeral: [32]u8 = rnd[64..96].*;

    const local = try std.Io.net.IpAddress.parse("127.0.0.1", BIND_PORT);
    const sock = try local.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer sock.close(io);

    const server = try std.Io.net.IpAddress.parse(server_ip, server_port);
    const conn = try connect(io, sock, &server, dcid, scid, client_random, ephemeral);

    var req_pkt: [1200]u8 = undefined;
    const request_packet = try buildRequest(conn.app_keys, conn.scid(), 0, 0, path, &req_pkt);
    try sock.send(io, &server, request_packet);

    return recvBody(io, sock, conn.app_keys, body_out);
}

/// Do TWO HTTP/3 GET round trips on ONE connection, on client bidi streams 0 then 4, returning both
/// decrypted bodies. This exercises request multiplexing (RC2): a single QUIC connection serving more
/// than one request. The two responses are read in send order.
///
/// Return:
/// - a struct of the two bodies (slices into body0_out / body1_out)
/// - an error if the handshake fails or either response is missing
pub fn fetchTwo(io: std.Io, server_ip: []const u8, server_port: u16, path0: []const u8, path1: []const u8, body0_out: []u8, body1_out: []u8) !struct { []const u8, []const u8 } {
    var rnd: [16 + 16 + 32 + 32]u8 = undefined;
    _ = std.os.linux.getrandom(&rnd, rnd.len, 0);
    const dcid = rnd[0..CID_LEN];
    const scid = rnd[16 .. 16 + CID_LEN];
    const client_random: [32]u8 = rnd[32..64].*;
    const ephemeral: [32]u8 = rnd[64..96].*;

    const local = try std.Io.net.IpAddress.parse("127.0.0.1", BIND_PORT);
    const sock = try local.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer sock.close(io);

    const server = try std.Io.net.IpAddress.parse(server_ip, server_port);
    const conn = try connect(io, sock, &server, dcid, scid, client_random, ephemeral);

    var req0_pkt: [1200]u8 = undefined;
    const req0 = try buildRequest(conn.app_keys, conn.scid(), 0, 0, path0, &req0_pkt);
    try sock.send(io, &server, req0);

    var req1_pkt: [1200]u8 = undefined;
    const req1 = try buildRequest(conn.app_keys, conn.scid(), 4, 1, path1, &req1_pkt);
    try sock.send(io, &server, req1);

    const body0 = try recvBody(io, sock, conn.app_keys, body0_out);
    const body1 = try recvBody(io, sock, conn.app_keys, body1_out);

    return .{ body0, body1 };
}

fn recvTimeout() std.Io.Timeout {
    return .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(3000), .clock = .awake } };
}
