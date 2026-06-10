//! zix http client config

const std = @import("std");

const zon_options = @import("zon_options");
/// Default zix http client user agent
pub const user_agent: []const u8 = zon_options.user_agent;

// --------------------------------------------------------- //

/// HTTP protocol version selector for client requests.
///
/// Note:
/// - HTTP_1 is implemented today (HTTP/1.1 over std.http.Client).
/// - HTTP_2 and HTTP_3 are reserved. Requests using them return
///   error.UnsupportedVersion until a backend is wired.
pub const Version = enum {
    HTTP_1,
    HTTP_2,
    HTTP_3,
};

// --------------------------------------------------------- //

/// Configuration for an HTTP client instance.
/// Pass to Http.Client.init(). Fields without defaults (allocator, io) are required.
pub const HttpClientConfig = struct {
    /// Backing allocator for response body and header copies. Caller owns and must outlive the client.
    allocator: std.mem.Allocator,
    /// Event-loop backend. Caller owns and must not deinit while the client is in use.
    io: std.Io,
    /// TCP connect timeout in milliseconds. 0 = no timeout (uses io backend default).
    connect_timeout_ms: u32 = 0,
    /// Time allowed to receive the first response byte after the request is sent, in milliseconds.
    /// 0 = no timeout. v1: stored for future enforcement, not yet applied.
    response_timeout_ms: u32 = 0,
    /// Time allowed to finish reading the full response body, in milliseconds.
    /// 0 = no timeout. v1: stored for future enforcement, not yet applied.
    read_timeout_ms: u32 = 0,
    /// Maximum response body size in bytes. Yields error.BodyTooLarge when exceeded.
    max_response_body: usize = 1024 * 1024 * 4,
    /// Follow HTTP 3xx redirects automatically up to max_redirects hops.
    follow_redirects: bool = true,
    /// Maximum number of automatic redirect hops. Ignored when follow_redirects is false.
    max_redirects: u8 = 3,
    /// Value sent in the User-Agent request header. Empty string omits the header entirely.
    user_agent: []const u8 = zon_options.user_agent,
    /// HTTP protocol version to use for requests. Default: .HTTP_1.
    /// HTTP_2 and HTTP_3 are reserved and currently yield error.UnsupportedVersion.
    version: Version = .HTTP_1,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix test: HttpClientConfig defaults" {
    const cfg: HttpClientConfig = .{
        .allocator = std.testing.allocator,
        .io = undefined,
    };
    try std.testing.expectEqual(@as(u32, 0), cfg.connect_timeout_ms);
    try std.testing.expectEqual(@as(u32, 0), cfg.response_timeout_ms);
    try std.testing.expectEqual(@as(u32, 0), cfg.read_timeout_ms);
    try std.testing.expectEqual(@as(usize, 1024 * 1024 * 4), cfg.max_response_body);
    try std.testing.expect(cfg.follow_redirects);
    try std.testing.expectEqual(@as(u8, 3), cfg.max_redirects);
    try std.testing.expectEqualStrings(user_agent, cfg.user_agent);
    try std.testing.expectEqual(Version.HTTP_1, cfg.version);
}
