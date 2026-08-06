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
const socket_poll = zix.utils.socket_poll;

const h3 = zix.Http3;
const crypto = h3.crypto;
const protection = h3.protection;
const keyschedule = h3.keyschedule;
const qpack = h3.qpack;
const packet = h3.packet;
const varint = h3.varint;
const tls_key_schedule = h3.tls_key_schedule;
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

    fn writeU8(self: *Writer, value: u8) void {
        self.buf[self.pos] = value;
        self.pos += 1;
    }

    fn writeU16(self: *Writer, value: u16) void {
        std.mem.writeInt(u16, self.buf[self.pos..][0..2], value, .big);
        self.pos += 2;
    }

    fn bytes(self: *Writer, data: []const u8) void {
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    /// Reserve a u16 length slot, returning its offset for a later patch.
    fn placeU16(self: *Writer) usize {
        const slot = self.pos;
        self.pos += 2;

        return slot;
    }

    /// Back-patch a u16 length slot with the bytes written since it was reserved.
    fn patchU16(self: *Writer, slot: usize) void {
        std.mem.writeInt(u16, self.buf[slot..][0..2], @intCast(self.pos - slot - 2), .big);
    }

    /// Reserve a u24 length slot (the TLS handshake message length), returning its offset.
    fn placeU24(self: *Writer) usize {
        const slot = self.pos;
        self.pos += 3;

        return slot;
    }

    /// Back-patch a u24 length slot with the bytes written since it was reserved.
    fn patchU24(self: *Writer, slot: usize) void {
        const len: u24 = @intCast(self.pos - slot - 3);
        self.buf[slot] = @intCast(len >> 16);
        self.buf[slot + 1] = @intCast((len >> 8) & 0xff);
        self.buf[slot + 2] = @intCast(len & 0xff);
    }
};

/// Serialize a minimal TLS 1.3 ClientHello (RFC 8446 4.1.2) offering AES_128_GCM_SHA256, X25519, and
/// ECDSA-P256 signatures, with our X25519 key share, ALPN h3, and the quic_transport_parameters
/// extension RFC 9001 3 requires of every QUIC endpoint. The zix h3 engine serves a client that
/// omits them, a server that honours the client's flow-control limits cannot: with no limits
/// announced, it has no credit to send a response with.
fn buildClientHello(buf: []u8, client_random: [32]u8, x25519_pub: [32]u8, scid: []const u8) []const u8 {
    var writer = Writer{ .buf = buf };

    writer.writeU8(0x01); // CLIENT_HELLO
    const body = writer.placeU24(); // handshake message length

    writer.writeU16(0x0303); // legacy_version TLS 1.2
    writer.bytes(&client_random);
    writer.writeU8(0x00); // empty session_id

    writer.writeU16(0x0002); // cipher_suites length
    writer.writeU16(0x1301); // TLS_AES_128_GCM_SHA256

    writer.writeU8(0x01); // compression methods length
    writer.writeU8(0x00); // null compression

    const exts = writer.placeU16();

    writer.writeU16(0x002b); // supported_versions
    const versions_ext = writer.placeU16();
    writer.writeU8(0x02); // list length
    writer.writeU16(0x0304); // TLS 1.3
    writer.patchU16(versions_ext);

    writer.writeU16(0x000a); // supported_groups
    const groups_ext = writer.placeU16();
    writer.writeU16(0x0002); // list length
    writer.writeU16(0x001d); // X25519
    writer.patchU16(groups_ext);

    writer.writeU16(0x000d); // signature_algorithms
    const sigalgs_ext = writer.placeU16();
    writer.writeU16(0x0002); // list length
    writer.writeU16(0x0403); // ECDSA_SECP256R1_SHA256
    writer.patchU16(sigalgs_ext);

    writer.writeU16(0x0033); // key_share
    const kshare = writer.placeU16();
    writer.writeU16(0x0024); // client_shares length (2 + 2 + 32)
    writer.writeU16(0x001d); // X25519
    writer.writeU16(0x0020); // key_exchange length 32
    writer.bytes(&x25519_pub);
    writer.patchU16(kshare);

    writer.writeU16(0x0010); // application_layer_protocol_negotiation
    const alpn = writer.placeU16();
    writer.writeU16(0x0003); // protocol list length
    writer.writeU8(0x02); // protocol name length
    writer.bytes("h3");
    writer.patchU16(alpn);

    writer.writeU16(0x0039); // quic_transport_parameters
    const params = writer.placeU16();
    var param_buf: [128]u8 = undefined;
    var param_len: usize = 0;
    param_len += varint.write(param_buf[param_len..], 0x0f); // initial_source_connection_id
    param_len += varint.write(param_buf[param_len..], scid.len);
    @memcpy(param_buf[param_len..][0..scid.len], scid);
    param_len += scid.len;
    putParam(&param_buf, &param_len, 0x04, 1 << 20); // initial_max_data
    putParam(&param_buf, &param_len, 0x05, 1 << 18); // initial_max_stream_data_bidi_local
    putParam(&param_buf, &param_len, 0x07, 1 << 18); // initial_max_stream_data_uni
    putParam(&param_buf, &param_len, 0x08, 8); // initial_max_streams_bidi
    putParam(&param_buf, &param_len, 0x09, 8); // initial_max_streams_uni
    writer.bytes(param_buf[0..param_len]);
    writer.patchU16(params);

    writer.patchU16(exts);
    writer.patchU24(body);

    return writer.buf[0..writer.pos];
}

/// Append one varint-coded transport parameter (id, then its varint value).
fn putParam(buf: []u8, len: *usize, id: u64, value: u64) void {
    len.* += varint.write(buf[len.*..], id);

    var value_buf: [8]u8 = undefined;
    const value_len = varint.write(&value_buf, value);
    len.* += varint.write(buf[len.*..], value_len);
    @memcpy(buf[len.*..][0..value_len], value_buf[0..value_len]);
    len.* += value_len;
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

/// Walk a decrypted 1-RTT payload and copy every STREAM frame belonging to `stream_id` into
/// `assembly` at its own offset, growing the contiguous prefix in `covered`. The ACK /
/// HANDSHAKE_DONE / control-stream frames the server leads with are skipped.
///
/// Note:
/// - Assembling before parsing is what makes this a client rather than a guess: a server is free
///   to split one HTTP/3 frame across packets, so a chunk taken on its own may start in the middle
///   of a frame header. Chunks that would leave a gap are ignored, the server retransmits them.
fn collectStream(payload: []const u8, stream_id: u64, assembly: []u8, covered: *usize) void {
    var pos: usize = 0;
    while (pos < payload.len) {
        const ftype = varint.read(payload[pos..]) catch return;
        pos += ftype.len;

        switch (ftype.value) {
            0x00, 0x01, 0x1e => {}, // PADDING, PING, HANDSHAKE_DONE
            0x02, 0x03 => { // ACK
                pos = skipAck(payload, pos, ftype.value == 0x03) orelse return;
            },
            0x08...0x0f => {
                const parsed = parseStream(payload[pos - ftype.len ..]) orelse return;
                if (parsed.id == stream_id) absorb(parsed, assembly, covered);

                pos = (pos - ftype.len) + parsed.consumed;
            },
            else => return,
        }
    }
}

/// Copy one stream chunk into the assembly buffer at its offset. A chunk that starts past the
/// contiguous prefix is dropped: it would leave a hole this simple assembler cannot track.
fn absorb(parsed: ParsedStream, assembly: []u8, covered: *usize) void {
    const start: usize = @intCast(parsed.offset);
    if (start > covered.*) return;
    if (start + parsed.data.len > assembly.len) return;

    @memcpy(assembly[start..][0..parsed.data.len], parsed.data);

    const end = start + parsed.data.len;
    if (end > covered.*) covered.* = end;
}

const ParsedStream = struct { id: u64, offset: u64, data: []const u8, consumed: usize };

/// Parse one STREAM frame (RFC 9000 19.8) at the start of `buf`.
fn parseStream(buf: []const u8) ?ParsedStream {
    const frame_type = buf[0];
    var pos: usize = 1;

    const id = varint.read(buf[pos..]) catch return null;
    pos += id.len;

    var offset_value: u64 = 0;
    if (frame_type & 0x04 != 0) {
        const offset = varint.read(buf[pos..]) catch return null;
        offset_value = offset.value;
        pos += offset.len;
    }

    const length: usize = if (frame_type & 0x02 != 0) blk: {
        const len = varint.read(buf[pos..]) catch return null;
        pos += len.len;
        break :blk @intCast(len.value);
    } else buf.len - pos;
    if (pos + length > buf.len) return null;

    return .{ .id = id.value, .offset = offset_value, .data = buf[pos .. pos + length], .consumed = pos + length };
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
        const field = varint.read(buf[pos..]) catch return null;
        pos += field.len;
    }
    if (ecn) {
        var ecn_idx: usize = 0;
        while (ecn_idx < 3) : (ecn_idx += 1) {
            const field = varint.read(buf[pos..]) catch return null;
            pos += field.len;
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

    var hello_buf: [512]u8 = undefined;
    const client_hello = buildClientHello(&hello_buf, client_random, x25519_pub, scid);

    var transcript = tls_key_schedule.Transcript.init();
    transcript.update(client_hello);

    // Initial payload: a CRYPTO frame carrying the ClientHello, padded over the 1200-byte floor.
    var init_payload: [1500]u8 = undefined;
    var payload_len: usize = 0;
    init_payload[payload_len] = 0x06; // CRYPTO
    payload_len += 1;
    payload_len += varint.write(init_payload[payload_len..], 0); // offset
    payload_len += varint.write(init_payload[payload_len..], client_hello.len);
    @memcpy(init_payload[payload_len..][0..client_hello.len], client_hello);
    payload_len += client_hello.len;
    while (payload_len < INITIAL_MIN) : (payload_len += 1) init_payload[payload_len] = 0x00; // PADDING

    var initial_pkt: [1600]u8 = undefined;
    const initial = try protection.sealInitial(&initial_pkt, initial_client, dcid, scid, 0, init_payload[0..payload_len]);

    // First send may hit an unbound server socket. A failure here is not fatal, the retransmit loop
    // below resends the Initial until the server answers or the budget is spent.
    sock.send(io, server, initial) catch {};

    // Receive ServerHello (Initial) then the Handshake flight, deriving keys as each arrives.
    var hs_keys: keyschedule.HandshakeKeys = undefined;
    var result = Connected{ .app_keys = undefined, .server_scid = undefined, .server_scid_len = 0 };
    var have_server_hello = false;
    var have_app = false;

    var init_pn: u32 = 0;
    var sends: usize = 1;
    while (!have_app) {
        var recv_buf: [2048]u8 = undefined;
        const msg = receiveWithin(io, sock, &recv_buf, HANDSHAKE_TIMEOUT_MS) orelse {
            // No response yet. The server's UDP socket may not be bound (there is no accept to poll),
            // or a packet was lost under load. Retransmit the Initial with a fresh packet number, the
            // QUIC reliability the handshake depends on, until the budget is spent.
            if (sends >= 25) break;
            sends += 1;
            init_pn += 1;

            // A send may report a stale ECONNREFUSED (ICMP port-unreachable queued before the
            // server bound its UDP socket). That is transient, keep retransmitting until the budget
            // is spent rather than giving up on the first refusal.
            var rt_pkt: [1600]u8 = undefined;
            const retransmit = protection.sealInitial(&rt_pkt, initial_client, dcid, scid, init_pn, init_payload[0..payload_len]) catch continue;
            sock.send(io, server, retransmit) catch continue;
            continue;
        };
        const data = msg.data;
        if (data.len == 0 or data[0] & 0x80 == 0) continue;

        const hdr = packet.parseLongHeader(data) catch continue;

        if (hdr.packet_type == 0 and !have_server_hello) {
            var open_buf: [2048]u8 = undefined;
            const opened = protection.openInitial(data, initial_server, &open_buf) catch continue;
            const server_hello = firstCryptoData(opened.payload) orelse continue;

            transcript.update(server_hello);
            const server_pub = serverKeyShare(server_hello) orelse return error.NoServerKeyShare;
            const shared = X25519.scalarmult(ephemeral, server_pub) catch return error.X25519;
            hs_keys = keyschedule.handshakeKeys(shared, transcript.current());

            @memcpy(result.server_scid[0..hdr.scid.len], hdr.scid);
            result.server_scid_len = hdr.scid.len;
            have_server_hello = true;
        } else if (hdr.packet_type == 2 and have_server_hello and !have_app) {
            var open_buf: [2048]u8 = undefined;
            const opened = protection.openHandshake(data, hs_keys.server, &open_buf) catch continue;
            const flight = firstCryptoData(opened.payload) orelse continue;

            transcript.update(flight);
            result.app_keys = keyschedule.applicationKeys(hs_keys.handshake_secret, transcript.current());
            have_app = true;
        }
    }

    if (!have_app) return error.HandshakeIncomplete;

    return result;
}

/// Authority every request carries. It matches the fixture certificate, so a server that refuses a
/// name it holds no certificate for still answers this client.
const AUTHORITY: []const u8 = "localhost";

/// Seal a 1-RTT request packet: an HTTP/3 HEADERS frame on `stream_id`, sealed under the client
/// 1-RTT keys with `client_pn`. The returned slice points into `pkt_buf`, which the caller owns.
///
/// Note:
/// - All four pseudo-headers RFC 9114 4.3.1 requires are sent. A server free to shape its own
///   handler surface can serve less, a gateway rebuilding an http1 request cannot: without
///   :scheme and :authority there is no absolute target and no Host to send upstream.
fn buildRequest(app_keys: keyschedule.AppKeys, server_scid: []const u8, stream_id: u64, client_pn: u32, path: []const u8, pkt_buf: []u8) ![]const u8 {
    var fields: [256]u8 = undefined;
    var fields_len: usize = 0;
    fields[0] = 0x00; // Required Insert Count 0
    fields[1] = 0x00; // Base 0
    fields_len = 2;
    fields_len += qpack.encodeStaticIndexedFieldLine(fields[fields_len..], 17); // :method GET
    fields_len += qpack.encodeStaticIndexedFieldLine(fields[fields_len..], 23); // :scheme https
    fields_len += qpack.encodePrefixedInt(fields[fields_len..], 4, 0x50, 0); // :authority literal, static name index 0
    fields_len += qpack.encodePrefixedInt(fields[fields_len..], 7, 0x00, AUTHORITY.len); // value length, non-Huffman
    @memcpy(fields[fields_len..][0..AUTHORITY.len], AUTHORITY);
    fields_len += AUTHORITY.len;
    fields_len += qpack.encodePrefixedInt(fields[fields_len..], 4, 0x50, 1); // :path literal, static name index 1
    fields_len += qpack.encodePrefixedInt(fields[fields_len..], 7, 0x00, path.len); // value length, non-Huffman
    @memcpy(fields[fields_len..][0..path.len], path);
    fields_len += path.len;

    var content: [512]u8 = undefined;
    var content_len: usize = 0;
    content[0] = 0x01; // HEADERS frame
    content_len = 1;
    content_len += varint.write(content[content_len..], fields_len);
    @memcpy(content[content_len..][0..fields_len], fields[0..fields_len]);
    content_len += fields_len;

    var req_payload: [1024]u8 = undefined;
    var payload_pos: usize = 0;
    req_payload[0] = 0x0b; // STREAM | LEN | FIN
    payload_pos = 1;
    payload_pos += varint.write(req_payload[payload_pos..], stream_id);
    payload_pos += varint.write(req_payload[payload_pos..], content_len); // data length
    @memcpy(req_payload[payload_pos..][0..content_len], content[0..content_len]);
    payload_pos += content_len;

    return try protection.sealShort(pkt_buf, app_keys.client, server_scid, client_pn, req_payload[0..payload_pos]);
}

/// Receive and decrypt 1-RTT packets, assembling `stream_id` until its HTTP/3 frames carry a
/// complete DATA body. Bare ACK / control packets the server interleaves are skipped.
fn recvBody(io: std.Io, sock: anytype, app_keys: keyschedule.AppKeys, stream_id: u64, body_out: []u8) ![]const u8 {
    var assembly: [ASSEMBLY_BYTES]u8 = undefined;
    var covered: usize = 0;

    var attempts: usize = 0;
    while (attempts < 16) : (attempts += 1) {
        var recv_buf: [2048]u8 = undefined;
        const msg = receiveWithin(io, sock, &recv_buf, RECV_TIMEOUT_MS) orelse break;
        const data = msg.data;
        if (data.len == 0 or data[0] & 0x80 != 0) continue;

        var open_buf: [2048]u8 = undefined;
        // This test client does a single short round trip, so the server's packet numbers stay well
        // under the truncation boundary: no prior-largest reconstruction is needed (null).
        const opened = protection.openShort(data, app_keys.server, CID_LEN, null, &open_buf) catch continue;
        collectStream(opened.payload, stream_id, &assembly, &covered);

        if (httpDataBody(assembly[0..covered], body_out)) |body| return body;
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
    io.random(&rnd);
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

    return recvBody(io, sock, conn.app_keys, 0, body_out);
}

/// Do TWO HTTP/3 GET round trips on ONE connection, on client bidi streams 0 then 4, returning both
/// decrypted bodies. This exercises request multiplexing: a single QUIC connection serving more
/// than one request. The two responses are read in send order.
///
/// Return:
/// - a struct of the two bodies (slices into body0_out / body1_out)
/// - an error if the handshake fails or either response is missing
pub fn fetchTwo(io: std.Io, server_ip: []const u8, server_port: u16, path0: []const u8, path1: []const u8, body0_out: []u8, body1_out: []u8) !struct { []const u8, []const u8 } {
    var rnd: [16 + 16 + 32 + 32]u8 = undefined;
    io.random(&rnd);
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

    const body0 = try recvBody(io, sock, conn.app_keys, 0, body0_out);
    const body1 = try recvBody(io, sock, conn.app_keys, 4, body1_out);

    return .{ body0, body1 };
}

/// Largest response one stream may assemble before the client gives up on it.
const ASSEMBLY_BYTES: usize = 64 * 1024;

/// Per-response wait for a 1-RTT packet.
const RECV_TIMEOUT_MS: u32 = 3000;

// Per-attempt wait for a handshake packet. Short enough that the Initial is retransmitted
// promptly when the first send is lost, the retransmit loop spends at most 25 of these.
const HANDSHAKE_TIMEOUT_MS: u32 = 600;

/// Receive one datagram within `timeout_ms`, or null when nothing arrived in time.
///
/// Note:
/// - Readiness first, then a plain receive. A timed std.Io receive races the receive against a
///   timer, which the Windows backend cannot do for a socket: it answers
///   error.ConcurrencyUnavailable, which every caller here reads as a lost packet and retries
///   until the budget is spent. Readiness plus a blocking receive needs no concurrency.
/// - A receive that fails after readiness is reported the same as a timeout: to the QUIC loops
///   above, both mean this attempt produced no packet.
fn receiveWithin(io: std.Io, sock: std.Io.net.Socket, buf: []u8, timeout_ms: u32) ?std.Io.net.IncomingMessage {
    const ready = socket_poll.waitReady(sock.handle, socket_poll.READABLE, timeout_ms) catch return null;
    if (!ready) return null;

    return sock.receive(io, buf) catch null;
}
