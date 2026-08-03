//! zix WebRTC answer builder (RFC 3264 6, RFC 8829 5.3, RFC 8839 4.3.2, RFC 8841 10.3).
//!
//! What:
//! - Turns an offer into the answer that goes back, and hands out the facts the layers under it
//!   need: which DTLS role zix took, which stream identifiers that leaves it, and which
//!   certificate hash to hold the peer to.
//!
//! Note:
//! - The origin line names 0.0.0.0 whatever address the answer is really on. RFC 8829 5.2.1 asks
//!   for a non-meaningful address there so a local address does not leak into a field nothing
//!   reads (RFC 8828). The real address goes in the connection line and the candidate, which are
//!   the two places it means something.
//! - The answer is always `a=setup:passive`, so zix is the DTLS server and opens data channels on
//!   odd stream identifiers. An offer that leaves no such role is refused rather than answered
//!   with a role no layer here can take.
//! - The transport port and the SCTP port are separate. The `m=` line carries the UDP port the
//!   candidate is on, and `a=sctp-port` carries the port inside the association.
//! - `a=tls-id` goes out only if the offer had one (RFC 8842 5.3), and the caller supplies it.
//!   Inventing one for an offer that carried none puts an attribute in the answer that RFC 8842
//!   says must not be there.
//! - One host candidate goes out, followed by `a=end-of-candidates`. An ice-lite agent gathers
//!   nothing and has nothing to trickle, so saying so at once saves the peer waiting
//!   (RFC 8838 8).

const std = @import("std");

const address = @import("address.zig");
const attribute = @import("attribute.zig");
const candidate = @import("candidate.zig");
const fingerprint = @import("fingerprint.zig");
const ice = @import("../ice/candidate.zig");
const line = @import("line.zig");
const media = @import("media.zig");
const offer = @import("offer.zig");
const setup = @import("setup.zig");
const stream_id = @import("../datachannel/stream_id.zig");

const IpAddress = std.Io.net.IpAddress;

/// Room for the longest answer this builds, with the longest ICE credentials RFC 8839 allows.
pub const MAX_ANSWER_BYTES: usize = 2048;

/// The SCTP port a WebRTC data channel uses (RFC 8832 6).
pub const DEFAULT_SCTP_PORT: u16 = 5000;

/// The largest message this endpoint will take, matching what browsers offer.
pub const DEFAULT_MAX_MESSAGE_SIZE: u32 = 256 * 1024;

/// The address the origin line names, so no local address leaks (RFC 8828).
pub const ORIGIN_ADDRESS: []const u8 = "IN IP4 0.0.0.0";

/// Everything that stops an answer from being built.
pub const Error = error{
    /// The output buffer is too small.
    NoSpace,
    /// The offer leaves this endpoint no DTLS role it can take.
    UnsupportedRole,
};

/// What this endpoint answers with.
pub const Config = struct {
    /// This endpoint's ICE username fragment.
    ice_ufrag: []const u8,
    /// This endpoint's ICE password, which is the key connectivity checks are signed with.
    ice_pwd: []const u8,
    /// The hash of the certificate this endpoint will present in the DTLS handshake.
    fingerprint: fingerprint.Fingerprint,
    /// Where this endpoint listens, which becomes the connection line and the one candidate.
    address: IpAddress,
    /// The SCTP port inside the association.
    sctp_port: u16 = DEFAULT_SCTP_PORT,
    /// The largest message this endpoint will take, or zero for any size.
    max_message_size: u32 = DEFAULT_MAX_MESSAGE_SIZE,
    /// Unique per session (RFC 8829 5.2.1), drawn by the caller.
    session_id: u64,
    /// This endpoint's identifier for the DTLS association, sent only when the offer had one.
    tls_id: ?[]const u8 = null,
};

/// The answer, and everything the layers under it need out of the exchange.
pub const Answer = struct {
    /// The answer text, borrowing the caller's output buffer.
    text: []const u8,
    /// The role this endpoint took, which is always passive.
    setup: setup.Role,
    /// Which half of the data channel identifier space that leaves this endpoint.
    stream_role: stream_id.Role,
    /// The certificate hash the peer's DTLS handshake has to match.
    peer_fingerprint: fingerprint.Fingerprint,
    /// The peer's ICE username fragment, borrowed from the offer.
    peer_ice_ufrag: []const u8,
    /// The peer's ICE password, borrowed from the offer.
    peer_ice_pwd: []const u8,
    /// The SCTP port the peer will use.
    peer_sctp_port: u16,
    /// The largest message the peer will take, or zero for any size.
    peer_max_message_size: u32,
};

/// Build the answer to an offer.
///
/// Note:
/// - Everything borrowed in the result points either at `out` or at the offer, so both have to
///   outlive it.
///
/// Param:
/// out - []u8 (at least MAX_ANSWER_BYTES)
/// offered - offer.Offer
/// config - Config
///
/// Return:
/// - Answer, whose text borrows `out`
/// - error.UnsupportedRole if the offer leaves no DTLS role this endpoint can take
/// - error.NoSpace
pub fn write(out: []u8, offered: offer.Offer, config: Config) Error!Answer {
    const role = setup.answerFor(offered.setup) catch return error.UnsupportedRole;
    const role_streams = setup.streamRole(role) catch return error.UnsupportedRole;

    var builder: Builder = .{ .out = out };

    try builder.addLine(.VERSION, "0");
    try builder.originLine(config.session_id);
    try builder.addLine(.SESSION_NAME, "-");
    try builder.addLine(.TIME, "0 0");

    // The group is echoed as the offer wrote it, because an answer that changes the tags in a
    // BUNDLE group is answering a different grouping (RFC 8843 7.2).
    if (offered.bundle) |group| try builder.addAttribute("group", group);

    try builder.addAttribute("ice-lite", null);
    try builder.mediaLine(address.portOf(config.address));
    try builder.connectionLine(config.address);
    try builder.addAttribute("ice-ufrag", config.ice_ufrag);
    try builder.addAttribute("ice-pwd", config.ice_pwd);
    try builder.addAttribute("ice-options", "ice2");
    try builder.fingerprintLine(&config.fingerprint);
    try builder.addAttribute(setup.ATTRIBUTE, role.name());

    if (offered.mid) |tag| try builder.addAttribute("mid", tag);
    if (offered.tls_id != null) {
        if (config.tls_id) |own| try builder.addAttribute("tls-id", own);
    }

    try builder.addNumber("sctp-port", config.sctp_port);
    try builder.addNumber("max-message-size", config.max_message_size);
    try builder.candidateLine(config.address);
    try builder.addAttribute(candidate.END_OF_CANDIDATES, null);

    return .{
        .text = out[0..builder.at],
        .setup = role,
        .stream_role = role_streams,
        .peer_fingerprint = offered.fingerprint,
        .peer_ice_ufrag = offered.ice_ufrag,
        .peer_ice_pwd = offered.ice_pwd,
        .peer_sctp_port = offered.sctp_port,
        .peer_max_message_size = offered.max_message_size,
    };
}

/// Appends lines to one buffer, tracking how far along it is.
const Builder = struct {
    out: []u8,
    at: usize = 0,

    /// Append one line of any type.
    fn addLine(self: *Builder, kind: line.Kind, value: []const u8) Error!void {
        const written = line.write(self.out[self.at..], kind, value) catch return error.NoSpace;

        self.at += written.len;
    }

    /// Append one attribute line, in either form.
    fn addAttribute(self: *Builder, name: []const u8, value: ?[]const u8) Error!void {
        const written = attribute.write(self.out[self.at..], name, value) catch return error.NoSpace;

        self.at += written.len;
    }

    /// Append an attribute whose value is a number.
    fn addNumber(self: *Builder, name: []const u8, value: u64) Error!void {
        var digits: [20]u8 = undefined;

        try self.addAttribute(name, writeNumber(&digits, value));
    }

    /// Append the origin line.
    fn originLine(self: *Builder, session_id: u64) Error!void {
        var value: [64]u8 = undefined;
        var digits: [20]u8 = undefined;

        const identifier = writeNumber(&digits, session_id);
        const total = 2 + identifier.len + 3 + ORIGIN_ADDRESS.len;

        if (value.len < total) return error.NoSpace;

        var at: usize = 0;
        at += copy(value[at..], "- ");
        at += copy(value[at..], identifier);
        at += copy(value[at..], " 1 ");
        at += copy(value[at..], ORIGIN_ADDRESS);

        try self.addLine(.ORIGIN, value[0..at]);
    }

    /// Append the media line for the data channel section.
    fn mediaLine(self: *Builder, port: u16) Error!void {
        var value: [96]u8 = undefined;
        const written = media.write(
            &value,
            media.DATA_CHANNEL_MEDIA,
            port,
            media.DATA_CHANNEL_PROTO,
            media.DATA_CHANNEL_FORMAT,
        ) catch return error.NoSpace;

        try self.addLine(.MEDIA, written);
    }

    /// Append the connection line.
    fn connectionLine(self: *Builder, host: IpAddress) Error!void {
        var text: [address.MAX_ADDRESS_LEN]u8 = undefined;
        const host_text = address.writeAddress(&text, host) catch return error.NoSpace;

        var value: [address.MAX_CONNECTION_LEN]u8 = undefined;
        const written = address.writeConnection(&value, address.familyOf(host), host_text) catch
            return error.NoSpace;

        try self.addLine(.CONNECTION, written);
    }

    /// Append the fingerprint attribute.
    fn fingerprintLine(self: *Builder, value: *const fingerprint.Fingerprint) Error!void {
        var text: [fingerprint.MAX_VALUE_LEN]u8 = undefined;
        const written = fingerprint.write(&text, value) catch return error.NoSpace;

        try self.addAttribute(fingerprint.ATTRIBUTE, written);
    }

    /// Append the one host candidate this endpoint has.
    fn candidateLine(self: *Builder, host: IpAddress) Error!void {
        const entry = ice.Candidate.host(host, .RTP, ice.SINGLE_ADDRESS_PREFERENCE);

        var value: [candidate.MAX_VALUE_LEN]u8 = undefined;
        const written = candidate.write(&value, entry) catch return error.NoSpace;

        try self.addAttribute(candidate.ATTRIBUTE, written);
    }
};

/// Write an unsigned number in base ten.
fn writeNumber(out: *[20]u8, value: u64) []const u8 {
    var digits: [20]u8 = undefined;
    var count: usize = 0;
    var left = value;

    while (true) {
        digits[count] = '0' + @as(u8, @intCast(left % 10));
        count += 1;
        left /= 10;

        if (left == 0) break;
    }

    for (0..count) |index| out[index] = digits[count - 1 - index];

    return out[0..count];
}

/// Copy into a buffer already known to be long enough.
fn copy(out: []u8, text: []const u8) usize {
    @memcpy(out[0..text.len], text);

    return text.len;
}

// --------------------------------------------------------------------------------------- //
// test cases

const session_mod = @import("session.zig");

const browser_offer: []const u8 =
    "v=0\r\n" ++
    "o=- 4611731400430051336 2 IN IP4 127.0.0.1\r\n" ++
    "s=-\r\n" ++
    "t=0 0\r\n" ++
    "a=group:BUNDLE 0\r\n" ++
    "a=msid-semantic: WMS\r\n" ++
    "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n" ++
    "c=IN IP4 0.0.0.0\r\n" ++
    "a=ice-ufrag:4ZcD\r\n" ++
    "a=ice-pwd:2/1muCWoOi3uLifh0NuRHlZ6\r\n" ++
    "a=ice-options:trickle\r\n" ++
    "a=fingerprint:sha-256 6B:8B:F0:65:5F:78:E2:51:3B:AC:6F:F3:3F:46:1B:35:" ++
    "DC:B8:5F:64:1A:24:C2:43:F0:A1:58:D0:A1:2C:19:08\r\n" ++
    "a=setup:actpass\r\n" ++
    "a=mid:0\r\n" ++
    "a=sctp-port:5000\r\n" ++
    "a=max-message-size:262144\r\n";

const listen_address: IpAddress = .{ .ip4 = .{ .bytes = .{ 203, 0, 113, 200 }, .port = 9091 } };

fn testConfig() Config {
    return .{
        .ice_ufrag = "zixA",
        .ice_pwd = "zixPasswordThatIsLongEnough",
        .fingerprint = fingerprint.compute("a certificate", .SHA_256),
        .address = listen_address,
        .session_id = 4_611_731_400_430_051_337,
    };
}

/// Build the answer to the browser offer, for the tests below.
fn answerText(out: []u8) ![]const u8 {
    const parsed = try offer.read(browser_offer);

    return (try write(out, parsed, testConfig())).text;
}

test "zix sdp: answer write, the result is a description that parses" {
    var out: [MAX_ANSWER_BYTES]u8 = undefined;
    const text = try answerText(&out);
    const parsed = try session_mod.parse(text);

    try std.testing.expectEqual(@as(usize, 1), parsed.sectionCount());
    try std.testing.expect(parsed.dataChannelSection() != null);
}

test "zix sdp: answer write, the first four lines are the ones JSEP requires" {
    var out: [MAX_ANSWER_BYTES]u8 = undefined;
    const text = try answerText(&out);

    try std.testing.expect(std.mem.startsWith(u8, text, "v=0\r\no=- 4611731400430051337 1 IN IP4 0.0.0.0\r\ns=-\r\nt=0 0\r\n"));
}

test "zix sdp: answer write, the origin line does not carry the real address" {
    var out: [MAX_ANSWER_BYTES]u8 = undefined;
    const text = try answerText(&out);
    const parsed = try session_mod.parse(text);
    const origin = line.find(parsed.session, .ORIGIN) orelse return error.TestUnexpectedResult;

    // RFC 8828: the address in this field is read by nobody and leaks a local address.
    try std.testing.expect(std.mem.indexOf(u8, origin.value, "203.0.113.200") == null);
    try std.testing.expect(std.mem.endsWith(u8, origin.value, ORIGIN_ADDRESS));
}

test "zix sdp: answer write, the answer is passive so zix is the DTLS server" {
    var out: [MAX_ANSWER_BYTES]u8 = undefined;
    const parsed = try offer.read(browser_offer);
    const result = try write(&out, parsed, testConfig());

    try std.testing.expectEqual(setup.Role.PASSIVE, result.setup);
    try std.testing.expectEqual(stream_id.Role.DTLS_SERVER, result.stream_role);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "a=setup:passive\r\n") != null);
}

test "zix sdp: answer write, an offer that needs zix to start the handshake is refused" {
    var text: [browser_offer.len]u8 = undefined;
    @memcpy(&text, browser_offer);

    const at = std.mem.indexOf(u8, &text, "setup:actpass").?;
    @memcpy(text[at..][0.."setup:passive".len], "setup:passive");

    const parsed = try offer.read(&text);

    var out: [MAX_ANSWER_BYTES]u8 = undefined;

    try std.testing.expectError(error.UnsupportedRole, write(&out, parsed, testConfig()));
}

test "zix sdp: answer write, the media section keeps the offered shape" {
    var out: [MAX_ANSWER_BYTES]u8 = undefined;
    const text = try answerText(&out);
    const parsed = try session_mod.parse(text);
    const section = parsed.dataChannelSection() orelse return error.TestUnexpectedResult;
    const media_line = try section.mediaLine();

    try std.testing.expect(media_line.isDataChannel());
    try std.testing.expect(!media_line.isRejected());
    try std.testing.expectEqual(@as(u16, 9091), media_line.port);
}

test "zix sdp: answer write, the transport port and the SCTP port are the two different numbers" {
    var out: [MAX_ANSWER_BYTES]u8 = undefined;
    const text = try answerText(&out);
    const parsed = try session_mod.parse(text);
    const section = parsed.dataChannelSection() orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(u16, 9091), (try section.mediaLine()).port);
    try std.testing.expectEqualStrings("5000", attribute.findValue(section.text, "sctp-port").?);
}

test "zix sdp: answer write, the connection line carries the real address" {
    var out: [MAX_ANSWER_BYTES]u8 = undefined;
    const text = try answerText(&out);
    const parsed = try session_mod.parse(text);
    const section = parsed.dataChannelSection() orelse return error.TestUnexpectedResult;
    const connection = line.find(section.text, .CONNECTION) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("IN IP4 203.0.113.200", connection.value);
}

test "zix sdp: answer write, an ice-lite agent says so and names its credentials" {
    var out: [MAX_ANSWER_BYTES]u8 = undefined;
    const text = try answerText(&out);
    const parsed = try session_mod.parse(text);
    const section = parsed.dataChannelSection() orelse return error.TestUnexpectedResult;

    try std.testing.expect(attribute.has(parsed.session, "ice-lite"));
    try std.testing.expectEqualStrings("zixA", attribute.findValue(section.text, "ice-ufrag").?);
    try std.testing.expectEqualStrings(
        "zixPasswordThatIsLongEnough",
        attribute.findValue(section.text, "ice-pwd").?,
    );
    try std.testing.expectEqualStrings("ice2", attribute.findValue(section.text, "ice-options").?);
}

test "zix sdp: answer write, the fingerprint is this endpoint's own" {
    var out: [MAX_ANSWER_BYTES]u8 = undefined;
    const text = try answerText(&out);
    const parsed = try session_mod.parse(text);
    const section = parsed.dataChannelSection() orelse return error.TestUnexpectedResult;

    const written = attribute.findValue(section.text, fingerprint.ATTRIBUTE).?;
    const read_back = try fingerprint.read(written);
    const own = fingerprint.compute("a certificate", .SHA_256);

    try std.testing.expect(own.matches(&read_back));
}

test "zix sdp: answer write, the peer's fingerprint comes back to be pinned against" {
    var out: [MAX_ANSWER_BYTES]u8 = undefined;
    const parsed = try offer.read(browser_offer);
    const result = try write(&out, parsed, testConfig());

    try std.testing.expectEqual(fingerprint.Function.SHA_256, result.peer_fingerprint.function);
    try std.testing.expectEqual(@as(u8, 0x6B), result.peer_fingerprint.digest[0]);
    try std.testing.expectEqualStrings("4ZcD", result.peer_ice_ufrag);
    try std.testing.expectEqualStrings("2/1muCWoOi3uLifh0NuRHlZ6", result.peer_ice_pwd);
    try std.testing.expectEqual(@as(u16, 5000), result.peer_sctp_port);
    try std.testing.expectEqual(@as(u32, 262_144), result.peer_max_message_size);
}

test "zix sdp: answer write, the bundle group and mid are echoed back" {
    var out: [MAX_ANSWER_BYTES]u8 = undefined;
    const text = try answerText(&out);
    const parsed = try session_mod.parse(text);
    const section = parsed.dataChannelSection() orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("BUNDLE 0", attribute.findValue(parsed.session, "group").?);
    try std.testing.expectEqualStrings("0", attribute.findValue(section.text, "mid").?);
}

test "zix sdp: answer write, an offer with no bundle group gets no group back" {
    const plain: []const u8 =
        "v=0\r\n" ++
        "o=- 1 2 IN IP4 127.0.0.1\r\n" ++
        "s=-\r\n" ++
        "t=0 0\r\n" ++
        "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n" ++
        "a=ice-ufrag:4ZcD\r\n" ++
        "a=ice-pwd:2/1muCWoOi3uLifh0NuRHlZ6\r\n" ++
        "a=fingerprint:sha-1 AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01\r\n" ++
        "a=setup:actpass\r\n" ++
        "a=sctp-port:5000\r\n";

    var out: [MAX_ANSWER_BYTES]u8 = undefined;
    const parsed_offer = try offer.read(plain);
    const result = try write(&out, parsed_offer, testConfig());
    const parsed = try session_mod.parse(result.text);
    const section = parsed.dataChannelSection() orelse return error.TestUnexpectedResult;

    try std.testing.expect(!attribute.has(parsed.session, "group"));
    try std.testing.expect(!attribute.has(section.text, "mid"));
}

test "zix sdp: answer write, one host candidate goes out and the list is closed" {
    var out: [MAX_ANSWER_BYTES]u8 = undefined;
    const text = try answerText(&out);
    const parsed = try session_mod.parse(text);
    const section = parsed.dataChannelSection() orelse return error.TestUnexpectedResult;

    const written = attribute.findValue(section.text, candidate.ATTRIBUTE).?;
    const entry = try candidate.read(written);

    try std.testing.expectEqualStrings("203.0.113.200", entry.address);
    try std.testing.expectEqual(@as(u16, 9091), entry.port);
    try std.testing.expectEqual(ice.Type.HOST, entry.kind);
    try std.testing.expect(attribute.has(section.text, candidate.END_OF_CANDIDATES));
}

test "zix sdp: answer write, a tls-id goes out only when the offer had one" {
    var out: [MAX_ANSWER_BYTES]u8 = undefined;
    const parsed_offer = try offer.read(browser_offer);

    var config = testConfig();
    config.tls_id = "dbc8de77cddef001be90";

    const result = try write(&out, parsed_offer, config);
    const parsed = try session_mod.parse(result.text);
    const section = parsed.dataChannelSection() orelse return error.TestUnexpectedResult;

    // RFC 8842 5.3: the offer carried none, so the answer must not carry one either.
    try std.testing.expect(!attribute.has(section.text, "tls-id"));
}

test "zix sdp: answer write, a tls-id is echoed when the offer carried one" {
    const with_id: []const u8 =
        "v=0\r\n" ++
        "o=- 1 2 IN IP4 127.0.0.1\r\n" ++
        "s=-\r\n" ++
        "t=0 0\r\n" ++
        "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n" ++
        "a=tls-id:abc3de65cddef001be82\r\n" ++
        "a=ice-ufrag:4ZcD\r\n" ++
        "a=ice-pwd:2/1muCWoOi3uLifh0NuRHlZ6\r\n" ++
        "a=fingerprint:sha-1 AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01\r\n" ++
        "a=setup:actpass\r\n" ++
        "a=sctp-port:5000\r\n";

    var out: [MAX_ANSWER_BYTES]u8 = undefined;
    const parsed_offer = try offer.read(with_id);

    var config = testConfig();
    config.tls_id = "dbc8de77cddef001be90";

    const result = try write(&out, parsed_offer, config);
    const parsed = try session_mod.parse(result.text);
    const section = parsed.dataChannelSection() orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("dbc8de77cddef001be90", attribute.findValue(section.text, "tls-id").?);
}

test "zix sdp: answer write, an IPv6 address comes out compressed in both places" {
    var bytes: [16]u8 = @splat(0);
    bytes[0] = 0x20;
    bytes[1] = 0x01;
    bytes[2] = 0x0d;
    bytes[3] = 0xb8;
    bytes[15] = 0x01;

    var out: [MAX_ANSWER_BYTES]u8 = undefined;
    const parsed_offer = try offer.read(browser_offer);

    var config = testConfig();
    config.address = .{ .ip6 = .{ .bytes = bytes, .port = 9091 } };

    const result = try write(&out, parsed_offer, config);
    const parsed = try session_mod.parse(result.text);
    const section = parsed.dataChannelSection() orelse return error.TestUnexpectedResult;
    const connection = line.find(section.text, .CONNECTION) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("IN IP6 2001:db8::1", connection.value);
    try std.testing.expect(std.mem.indexOf(u8, section.text, "2001:db8::1 9091 typ host") != null);
}

test "zix sdp: answer write, the max message size is this endpoint's own" {
    var out: [MAX_ANSWER_BYTES]u8 = undefined;
    const parsed_offer = try offer.read(browser_offer);

    var config = testConfig();
    config.max_message_size = 65_536;

    const result = try write(&out, parsed_offer, config);
    const parsed = try session_mod.parse(result.text);
    const section = parsed.dataChannelSection() orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("65536", attribute.findValue(section.text, "max-message-size").?);
}

test "zix sdp: answer write, a short buffer errors instead of writing a partial answer" {
    var out: [64]u8 = undefined;
    const parsed_offer = try offer.read(browser_offer);

    try std.testing.expectError(error.NoSpace, write(&out, parsed_offer, testConfig()));
}

test "zix sdp: answer write, the answer reads back as an offer would" {
    // The strongest check available without a peer: the answer this endpoint builds is itself a
    // description the reader accepts, with every field it was given.
    var out: [MAX_ANSWER_BYTES]u8 = undefined;
    const text = try answerText(&out);
    const parsed = try offer.read(text);

    try std.testing.expectEqualStrings("zixA", parsed.ice_ufrag);
    try std.testing.expectEqualStrings("zixPasswordThatIsLongEnough", parsed.ice_pwd);
    try std.testing.expectEqual(setup.Role.PASSIVE, parsed.setup);
    try std.testing.expectEqual(@as(u16, 5000), parsed.sctp_port);
    try std.testing.expectEqual(DEFAULT_MAX_MESSAGE_SIZE, parsed.max_message_size);
    try std.testing.expect(parsed.ice_lite);
    try std.testing.expect(parsed.ice2);
}
