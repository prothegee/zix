//! zix WebRTC offer reader (RFC 8829 5.9, RFC 8839 4.3, RFC 8841 10.2, RFC 8842 5.2).
//!
//! What:
//! - Reads a data channel offer down to the handful of things an answer and the layers under it
//!   need: who the peer is on ICE, what certificate to expect, who starts the DTLS handshake,
//!   and how the SCTP association is to be set up.
//!
//! Note:
//! - An attribute is looked for in the media section first and at session level second. That is
//!   the rule for the ICE credentials (RFC 8839 5.4) and for the fingerprint (RFC 8122 5), and
//!   browsers put both in the media section while the RFC examples often put them at session
//!   level. Searching one place only reads half of what is out there.
//! - Only the first data channel section is read. A bundled session can carry audio and video
//!   sections that zix has nothing to say about, and refusing the whole offer over them would
//!   turn a session zix can partly serve into one it cannot serve at all.
//! - Everything borrows the offer text, apart from the fingerprint, which is copied because it
//!   is checked against a certificate that arrives later.
//! - A missing `a=sctp-port` makes the section invalid (RFC 8841 5.1), so it is an error rather
//!   than a default. A missing `a=max-message-size` has a default of 64 KB (RFC 8841 6.1), and a
//!   value of zero means the peer will take a message of any size.

const std = @import("std");

const attribute = @import("attribute.zig");
const fingerprint = @import("fingerprint.zig");
const media = @import("media.zig");
const session = @import("session.zig");
const setup = @import("setup.zig");

/// What a peer will take when it says nothing (RFC 8841 6.1).
pub const DEFAULT_MAX_MESSAGE_SIZE: u32 = 64 * 1024;

/// Everything that stops an offer from being read.
pub const Error = error{
    /// A line without a type character followed by an equals sign.
    Malformed,
    /// A version this parser does not implement.
    UnsupportedVersion,
    /// One of the four fields RFC 8866 5 makes mandatory is missing.
    MissingField,
    /// No media section describing a WebRTC data channel.
    NoDataChannel,
    /// The data channel section was offered with a port of zero.
    Rejected,
    /// A port that is not a number, or one that does not fit.
    BadPort,
    /// A hash function this endpoint does not implement.
    UnsupportedFunction,
    /// A fingerprint whose hex is not pairs, or is the wrong length for its function.
    BadDigest,
    /// A setup value outside the four RFC 4145 4 defines.
    UnknownRole,
};

/// A data channel offer, read down to what an answer needs.
pub const Offer = struct {
    /// The whole description, borrowed.
    text: []const u8,
    /// The data channel section, borrowed.
    section: session.Section,
    /// The section's `m=` line.
    media_line: media.Media,
    /// The peer's ICE username fragment.
    ice_ufrag: []const u8,
    /// The peer's ICE password, which is the key for connectivity checks.
    ice_pwd: []const u8,
    /// Whether the peer said it is an ice-lite agent, in which case neither side sends checks.
    ice_lite: bool,
    /// Whether the peer announced RFC 8445 support with an "ice2" option.
    ice2: bool,
    /// The certificate hash the DTLS handshake has to match.
    fingerprint: fingerprint.Fingerprint,
    /// Who the peer says will start the DTLS handshake.
    setup: setup.Role,
    /// The section's identification tag, which an answer echoes back.
    mid: ?[]const u8,
    /// The BUNDLE group as the peer wrote it, when there was one.
    bundle: ?[]const u8,
    /// The peer's identifier for the DTLS association, which the answer only carries if the
    /// offer did (RFC 8842 5.3).
    tls_id: ?[]const u8,
    /// The SCTP port inside the association, which is not the transport port.
    sctp_port: u16,
    /// The largest message the peer will take, or zero for any size.
    max_message_size: u32,
};

/// Read a data channel offer.
///
/// Param:
/// text - []const u8 (borrowed, must outlive the result)
///
/// Return:
/// - Offer borrowing `text`
/// - error.Malformed, error.UnsupportedVersion, error.MissingField
/// - error.NoDataChannel if no section describes a WebRTC data channel
/// - error.Rejected if the data channel section was offered with a port of zero
/// - error.MissingField if the ICE credentials, the fingerprint, the setup role, or the SCTP
///   port is not there
pub fn read(text: []const u8) Error!Offer {
    const description = try session.parse(text);
    const section = description.dataChannelSection() orelse return error.NoDataChannel;
    const media_line = try section.mediaLine();

    if (media_line.isRejected()) return error.Rejected;

    const ufrag = lookup(description, section, "ice-ufrag") orelse return error.MissingField;
    const password = lookup(description, section, "ice-pwd") orelse return error.MissingField;
    const fingerprint_value = lookup(description, section, fingerprint.ATTRIBUTE) orelse
        return error.MissingField;
    const setup_value = lookup(description, section, setup.ATTRIBUTE) orelse return error.MissingField;
    const sctp_port = lookup(description, section, "sctp-port") orelse return error.MissingField;

    return .{
        .text = text,
        .section = section,
        .media_line = media_line,
        .ice_ufrag = ufrag,
        .ice_pwd = password,
        .ice_lite = attribute.has(description.session, "ice-lite"),
        .ice2 = hasIce2(description, section),
        .fingerprint = try fingerprint.read(fingerprint_value),
        .setup = try setup.read(setup_value),
        .mid = attribute.findValue(section.text, "mid"),
        .bundle = attribute.findValue(description.session, "group"),
        .tls_id = lookup(description, section, "tls-id"),
        .sctp_port = std.fmt.parseInt(u16, sctp_port, 10) catch return error.BadPort,
        .max_message_size = try readMaxMessageSize(description, section),
    };
}

/// An attribute value, looked for in the media section and then at session level.
fn lookup(description: session.Description, section: session.Section, name: []const u8) ?[]const u8 {
    if (attribute.findValue(section.text, name)) |found| return found;

    return attribute.findValue(description.session, name);
}

/// Whether either level announced the "ice2" option.
fn hasIce2(description: session.Description, section: session.Section) bool {
    const options = lookup(description, section, "ice-options") orelse return false;

    var words = std.mem.tokenizeScalar(u8, options, ' ');
    while (words.next()) |word| {
        if (std.mem.eql(u8, word, "ice2")) return true;
    }

    return false;
}

/// The peer's message ceiling, or the RFC 8841 6.1 default when it said nothing.
fn readMaxMessageSize(description: session.Description, section: session.Section) Error!u32 {
    const value = lookup(description, section, "max-message-size") orelse
        return DEFAULT_MAX_MESSAGE_SIZE;

    return std.fmt.parseInt(u32, value, 10) catch error.BadPort;
}

// --------------------------------------------------------------------------------------- //
// test cases

/// A data channel offer in the shape a browser sends one.
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

test "zix sdp: offer read, a browser offer reads field for field" {
    const parsed = try read(browser_offer);

    try std.testing.expectEqualStrings("4ZcD", parsed.ice_ufrag);
    try std.testing.expectEqualStrings("2/1muCWoOi3uLifh0NuRHlZ6", parsed.ice_pwd);
    try std.testing.expectEqual(setup.Role.ACTPASS, parsed.setup);
    try std.testing.expectEqualStrings("0", parsed.mid.?);
    try std.testing.expectEqualStrings("BUNDLE 0", parsed.bundle.?);
    try std.testing.expectEqual(@as(u16, 5000), parsed.sctp_port);
    try std.testing.expectEqual(@as(u32, 262_144), parsed.max_message_size);
}

test "zix sdp: offer read, the fingerprint is copied out whole" {
    const parsed = try read(browser_offer);

    try std.testing.expectEqual(fingerprint.Function.SHA_256, parsed.fingerprint.function);
    try std.testing.expectEqual(@as(usize, 32), parsed.fingerprint.len);
    try std.testing.expectEqual(@as(u8, 0x6B), parsed.fingerprint.digest[0]);
    try std.testing.expectEqual(@as(u8, 0x08), parsed.fingerprint.digest[31]);
}

test "zix sdp: offer read, the transport port and the SCTP port are different numbers" {
    const parsed = try read(browser_offer);

    // The `m=` line carries 9, the placeholder a trickling offerer uses, and the association
    // runs on 5000. Reading one for the other builds an answer that connects to nothing.
    try std.testing.expectEqual(@as(u16, 9), parsed.media_line.port);
    try std.testing.expectEqual(@as(u16, 5000), parsed.sctp_port);
}

test "zix sdp: offer read, session level credentials are found" {
    const session_level: []const u8 =
        "v=0\r\n" ++
        "o=- 1 2 IN IP4 127.0.0.1\r\n" ++
        "s=-\r\n" ++
        "t=0 0\r\n" ++
        "a=ice-ufrag:8hhY\r\n" ++
        "a=ice-pwd:asd88fgpdd777uzjYhagZg\r\n" ++
        "a=ice-options:ice2\r\n" ++
        "a=fingerprint:sha-1 AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01\r\n" ++
        "a=setup:actpass\r\n" ++
        "m=application 54111 UDP/DTLS/SCTP webrtc-datachannel\r\n" ++
        "a=sctp-port:5000\r\n";

    const parsed = try read(session_level);

    try std.testing.expectEqualStrings("8hhY", parsed.ice_ufrag);
    try std.testing.expectEqual(fingerprint.Function.SHA_1, parsed.fingerprint.function);
    try std.testing.expect(parsed.ice2);
}

test "zix sdp: offer read, a media level value wins over a session level one" {
    const both: []const u8 =
        "v=0\r\n" ++
        "o=- 1 2 IN IP4 127.0.0.1\r\n" ++
        "s=-\r\n" ++
        "t=0 0\r\n" ++
        "a=ice-ufrag:session\r\n" ++
        "a=ice-pwd:sessionpasswordthatislong\r\n" ++
        "a=fingerprint:sha-1 AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01\r\n" ++
        "a=setup:actpass\r\n" ++
        "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n" ++
        "a=ice-ufrag:media\r\n" ++
        "a=ice-pwd:mediapasswordthatisalsolong\r\n" ++
        "a=sctp-port:5000\r\n";

    const parsed = try read(both);

    try std.testing.expectEqualStrings("media", parsed.ice_ufrag);
    try std.testing.expectEqualStrings("mediapasswordthatisalsolong", parsed.ice_pwd);
}

test "zix sdp: offer read, a missing max message size takes the RFC default" {
    const without: []const u8 =
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

    const parsed = try read(without);

    try std.testing.expectEqual(DEFAULT_MAX_MESSAGE_SIZE, parsed.max_message_size);
}

test "zix sdp: offer read, a zero max message size means any size" {
    var text: [browser_offer.len]u8 = undefined;
    @memcpy(&text, browser_offer);

    const at = std.mem.indexOf(u8, &text, "max-message-size:262144").?;
    @memcpy(text[at..][0.."max-message-size:000000".len], "max-message-size:000000");

    const parsed = try read(&text);

    try std.testing.expectEqual(@as(u32, 0), parsed.max_message_size);
}

test "zix sdp: offer read, a missing SCTP port is refused" {
    const without: []const u8 =
        "v=0\r\n" ++
        "o=- 1 2 IN IP4 127.0.0.1\r\n" ++
        "s=-\r\n" ++
        "t=0 0\r\n" ++
        "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n" ++
        "a=ice-ufrag:4ZcD\r\n" ++
        "a=ice-pwd:2/1muCWoOi3uLifh0NuRHlZ6\r\n" ++
        "a=fingerprint:sha-1 AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01\r\n" ++
        "a=setup:actpass\r\n";

    // RFC 8841 5.1: with no sctp-port the section is invalid, so there is nothing to default to.
    try std.testing.expectError(error.MissingField, read(without));
}

test "zix sdp: offer read, a missing fingerprint is refused" {
    const without: []const u8 =
        "v=0\r\n" ++
        "o=- 1 2 IN IP4 127.0.0.1\r\n" ++
        "s=-\r\n" ++
        "t=0 0\r\n" ++
        "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n" ++
        "a=ice-ufrag:4ZcD\r\n" ++
        "a=ice-pwd:2/1muCWoOi3uLifh0NuRHlZ6\r\n" ++
        "a=setup:actpass\r\n" ++
        "a=sctp-port:5000\r\n";

    // Without it there is nothing to check the peer's certificate against, and the handshake
    // would complete against whoever answered.
    try std.testing.expectError(error.MissingField, read(without));
}

test "zix sdp: offer read, a missing ICE password is refused" {
    const without: []const u8 =
        "v=0\r\n" ++
        "o=- 1 2 IN IP4 127.0.0.1\r\n" ++
        "s=-\r\n" ++
        "t=0 0\r\n" ++
        "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n" ++
        "a=ice-ufrag:4ZcD\r\n" ++
        "a=fingerprint:sha-1 AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01\r\n" ++
        "a=setup:actpass\r\n" ++
        "a=sctp-port:5000\r\n";

    try std.testing.expectError(error.MissingField, read(without));
}

test "zix sdp: offer read, a session with no data channel is refused" {
    const audio_only: []const u8 =
        "v=0\r\n" ++
        "o=- 1 2 IN IP4 127.0.0.1\r\n" ++
        "s=-\r\n" ++
        "t=0 0\r\n" ++
        "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n" ++
        "a=mid:0\r\n";

    try std.testing.expectError(error.NoDataChannel, read(audio_only));
}

test "zix sdp: offer read, a data channel section offered with port zero is refused" {
    var text: [browser_offer.len]u8 = undefined;
    @memcpy(&text, browser_offer);

    const at = std.mem.indexOf(u8, &text, "m=application 9").?;
    @memcpy(text[at..][0.."m=application 0".len], "m=application 0");

    try std.testing.expectError(error.Rejected, read(&text));
}

test "zix sdp: offer read, the data channel section of a bundle is the one read" {
    const bundled: []const u8 =
        "v=0\r\n" ++
        "o=- 1 2 IN IP4 127.0.0.1\r\n" ++
        "s=-\r\n" ++
        "t=0 0\r\n" ++
        "a=group:BUNDLE 0 1\r\n" ++
        "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n" ++
        "a=ice-ufrag:audio\r\n" ++
        "a=mid:0\r\n" ++
        "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n" ++
        "a=ice-ufrag:4ZcD\r\n" ++
        "a=ice-pwd:2/1muCWoOi3uLifh0NuRHlZ6\r\n" ++
        "a=fingerprint:sha-1 AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01\r\n" ++
        "a=setup:actpass\r\n" ++
        "a=mid:1\r\n" ++
        "a=sctp-port:5000\r\n";

    const parsed = try read(bundled);

    try std.testing.expectEqualStrings("4ZcD", parsed.ice_ufrag);
    try std.testing.expectEqualStrings("1", parsed.mid.?);
    try std.testing.expectEqualStrings("BUNDLE 0 1", parsed.bundle.?);
}

test "zix sdp: offer read, ice-lite is noticed" {
    const lite: []const u8 =
        "v=0\r\n" ++
        "o=- 1 2 IN IP4 127.0.0.1\r\n" ++
        "s=-\r\n" ++
        "t=0 0\r\n" ++
        "a=ice-lite\r\n" ++
        "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n" ++
        "a=ice-ufrag:4ZcD\r\n" ++
        "a=ice-pwd:2/1muCWoOi3uLifh0NuRHlZ6\r\n" ++
        "a=fingerprint:sha-1 AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01\r\n" ++
        "a=setup:actpass\r\n" ++
        "a=sctp-port:5000\r\n";

    const parsed = try read(lite);

    try std.testing.expect(parsed.ice_lite);
    try std.testing.expect(!(try read(browser_offer)).ice_lite);
}

test "zix sdp: offer read, the ice2 option is picked out of a list" {
    const options: []const u8 =
        "v=0\r\n" ++
        "o=- 1 2 IN IP4 127.0.0.1\r\n" ++
        "s=-\r\n" ++
        "t=0 0\r\n" ++
        "a=ice-options:trickle ice2\r\n" ++
        "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n" ++
        "a=ice-ufrag:4ZcD\r\n" ++
        "a=ice-pwd:2/1muCWoOi3uLifh0NuRHlZ6\r\n" ++
        "a=fingerprint:sha-1 AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01\r\n" ++
        "a=setup:actpass\r\n" ++
        "a=sctp-port:5000\r\n";

    try std.testing.expect((try read(options)).ice2);
    try std.testing.expect(!(try read(browser_offer)).ice2);
}

test "zix sdp: offer read, a tls-id is carried when there is one" {
    try std.testing.expect((try read(browser_offer)).tls_id == null);

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

    try std.testing.expectEqualStrings("abc3de65cddef001be82", (try read(with_id)).tls_id.?);
}

test "zix sdp: offer read, a malformed description is refused" {
    try std.testing.expectError(error.Malformed, read("v=0\r\nbroken\r\n"));
    try std.testing.expectError(error.MissingField, read("v=0\r\n"));
}

test "zix sdp: offer read, an unreadable fingerprint is refused" {
    var text: [browser_offer.len]u8 = undefined;
    @memcpy(&text, browser_offer);

    const at = std.mem.indexOf(u8, &text, "sha-256").?;
    @memcpy(text[at..][0.."sha-xxx".len], "sha-xxx");

    try std.testing.expectError(error.UnsupportedFunction, read(&text));
}

test "zix sdp: offer read, an unreadable setup role is refused" {
    var text: [browser_offer.len]u8 = undefined;
    @memcpy(&text, browser_offer);

    const at = std.mem.indexOf(u8, &text, "setup:actpass").?;
    @memcpy(text[at..][0.."setup:actxxxx".len], "setup:actxxxx");

    try std.testing.expectError(error.UnknownRole, read(&text));
}

test "zix sdp: offer read, an offer terminated with bare newlines is accepted" {
    var text: [browser_offer.len]u8 = undefined;
    @memcpy(&text, browser_offer);

    // What a description looks like after a signaling path normalised its line endings.
    var trimmed: [browser_offer.len]u8 = undefined;
    var at: usize = 0;
    for (text) |byte| {
        if (byte == '\r') continue;

        trimmed[at] = byte;
        at += 1;
    }

    const parsed = try read(trimmed[0..at]);

    try std.testing.expectEqualStrings("4ZcD", parsed.ice_ufrag);
    try std.testing.expectEqual(@as(u16, 5000), parsed.sctp_port);
}
