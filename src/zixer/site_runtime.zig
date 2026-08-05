//! zixer site runtime: the bound listener a started site owns

const std = @import("std");

const acme_listener = @import("acme_listener.zig");
const site_cfg = @import("site_cfg.zig");
const site_serve = @import("site_serve.zig");

/// The port the CA validates http-01 on (rfc 8555 8.3).
const ACME_HTTP_PORT: u16 = 80;

/// One started site inside the daemon.
///
/// Note:
/// - An http1 or http2 site with upstreams or public_dir serves the edge
///   loop (phases 3, 4, and 7). Every other engine binds and holds its
///   socket, so the port is owned and a collision surfaces at start time,
///   the loop attaches in its own phase.
/// - A TLS site with acme keys also owns the port 80 companion listener,
///   see companionPort.
pub const SiteRuntime = struct {
    name: []const u8,
    engine: site_cfg.Engine,
    port: u16,
    listener: Listener,
    /// The bound acme companion, held only by a TLS site with acme keys.
    challenge: ?*acme_listener.State = null,

    /// What the site holds: a serving proxy edge, or the bare bound socket
    /// (tcp engines listen, udp engines bind a datagram socket).
    const Listener = union(enum) {
        proxy_edge: *site_serve.ServeState,
        tcp: std.Io.net.Server,
        udp: std.Io.net.Socket,
    };

    /// Bind the listener for one validated site cfg.
    ///
    /// Param:
    /// allocator - std.mem.Allocator (owns the duped name, long-lived)
    /// io - std.Io
    /// name - []const u8 (site file name, copied)
    /// cfg - site_cfg.SiteCfg (must have passed validation: engine and port set)
    /// kernel_backlog - u31 (site override or the main.cfg default)
    ///
    /// Return:
    /// - SiteRuntime holding the bound socket
    /// - error.SiteCfgIncomplete when engine, port, or ip did not survive parse
    /// - error.AddressInUse when another listener owns ip:port
    pub fn bind(allocator: std.mem.Allocator, io: std.Io, name: []const u8, cfg: site_cfg.SiteCfg, kernel_backlog: u31) !SiteRuntime {
        const engine = cfg.engine orelse return error.SiteCfgIncomplete;
        const port = cfg.port orelse return error.SiteCfgIncomplete;
        const addr = std.Io.net.IpAddress.parse(cfg.ip, port) catch return error.SiteCfgIncomplete;

        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);

        // Tcp listens with reuse_address like every zix engine: without it a
        // restart right after live traffic hits TIME_WAIT and fails the
        // rebind. Same-port collisions between sites are the daemon
        // registry's check, the kernel no longer reports them here. Udp has
        // no TIME_WAIT, so it keeps the strict bind.
        var listener: Listener = switch (engine) {
            .HTTP1, .HTTP2, .GRPC => blk: {
                var server = try addr.listen(io, .{ .reuse_address = true, .kernel_backlog = kernel_backlog });

                if ((engine == .HTTP1 or engine == .HTTP2) and (cfg.upstreams.len > 0 or cfg.public_dir != null)) {
                    const state = site_serve.ServeState.create(allocator, io, server, &cfg, port) catch |err| {
                        server.deinit(io);
                        return err;
                    };

                    break :blk .{ .proxy_edge = state };
                }

                break :blk .{ .tcp = server };
            },
            .HTTP3, .UDP => .{ .udp = try addr.bind(io, .{ .mode = .dgram, .protocol = .udp }) },
        };
        errdefer closeListener(&listener, io);

        // A TLS site with acme keys answers the CA on port 80 beside its
        // main listener. A bind failure (port taken, no privilege) fails
        // the whole start: a silent half-start would break renewal.
        var challenge: ?*acme_listener.State = null;
        if (companionPort(&cfg)) |challenge_port| {
            const challenge_addr = std.Io.net.IpAddress.parse(cfg.ip, challenge_port) catch return error.SiteCfgIncomplete;
            const challenge_server = try challenge_addr.listen(io, .{ .reuse_address = true, .kernel_backlog = kernel_backlog });

            challenge = acme_listener.State.create(allocator, io, challenge_server, cfg.acme_webroot, cfg.acme_proxy, cfg.ip, challenge_port, port) catch |err| {
                var orphan = challenge_server;
                orphan.deinit(io);
                return err;
            };
        }

        return .{ .name = owned_name, .engine = engine, .port = port, .listener = listener, .challenge = challenge };
    }

    /// Stop any serve loop, close the listeners, release the name.
    pub fn unbind(runtime: *SiteRuntime, allocator: std.mem.Allocator, io: std.Io) void {
        if (runtime.challenge) |state| state.shutdown();
        closeListener(&runtime.listener, io);

        allocator.free(runtime.name);
    }

    /// Whether this started site holds the given port (its own listener or
    /// its acme companion). The daemon registry checks collisions with it.
    pub fn ownsPort(runtime: *const SiteRuntime, port: u16) bool {
        if (runtime.port == port) return true;
        if (runtime.challenge) |state| return state.port == port;

        return false;
    }
};

fn closeListener(listener: *SiteRuntime.Listener, io: std.Io) void {
    switch (listener.*) {
        .proxy_edge => |state| state.shutdown(),
        .tcp => |*server| server.deinit(io),
        .udp => |socket| socket.close(io),
    }
}

/// The companion challenge port a validated cfg calls for: port 80 on a
/// TLS site with acme keys. A cleartext site answers the challenge path on
/// its own listener, and a site already on 80 needs no companion.
pub fn companionPort(cfg: *const site_cfg.SiteCfg) ?u16 {
    if (!cfg.tls) return null;
    if (cfg.acme_webroot == null and cfg.acme_proxy == null) return null;
    if ((cfg.port orelse 0) == ACME_HTTP_PORT) return null;

    return ACME_HTTP_PORT;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix zixer: site runtime, incomplete cfg refuses to bind" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const no_engine = site_cfg.SiteCfg{ .port = 39860 };
    try std.testing.expectError(error.SiteCfgIncomplete, SiteRuntime.bind(std.testing.allocator, io, "a.cfg", no_engine, 64));

    const no_port = site_cfg.SiteCfg{ .engine = .HTTP1 };
    try std.testing.expectError(error.SiteCfgIncomplete, SiteRuntime.bind(std.testing.allocator, io, "a.cfg", no_port, 64));
}

test "zix zixer: site runtime, tcp bind rebinds cleanly after unbind" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cfg = site_cfg.SiteCfg{ .engine = .HTTP1, .ip = "127.0.0.1", .port = 39861 };

    var first = try SiteRuntime.bind(std.testing.allocator, io, "a.cfg", cfg, 64);
    try std.testing.expectEqualStrings("a.cfg", first.name);
    try std.testing.expectEqual(@as(u16, 39861), first.port);
    try std.testing.expect(first.listener == .tcp);

    first.unbind(std.testing.allocator, io);

    // reuse_address makes the rebind immediate. Same-port collisions between
    // sites are the daemon registry's check, not the kernel's.
    var again = try SiteRuntime.bind(std.testing.allocator, io, "a.cfg", cfg, 64);
    again.unbind(std.testing.allocator, io);
}

test "zix zixer: site runtime, udp engine binds a datagram socket" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cfg = site_cfg.SiteCfg{ .engine = .UDP, .ip = "127.0.0.1", .port = 39862 };

    var runtime = try SiteRuntime.bind(std.testing.allocator, io, "media.cfg", cfg, 64);
    try std.testing.expect(runtime.listener == .udp);

    try std.testing.expectError(error.AddressInUse, SiteRuntime.bind(std.testing.allocator, io, "b.cfg", cfg, 64));

    runtime.unbind(std.testing.allocator, io);
}

test "zix zixer: site runtime, http1 with upstreams serves and unbind frees the port" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const upstreams = [_]site_cfg.Upstream{.{ .host = "127.0.0.1", .port = 39859 }};
    const cfg = site_cfg.SiteCfg{ .engine = .HTTP1, .ip = "127.0.0.1", .port = 39872, .upstreams = &upstreams };

    var runtime = try SiteRuntime.bind(std.testing.allocator, io, "proxy.cfg", cfg, 64);
    try std.testing.expect(runtime.listener == .proxy_edge);

    runtime.unbind(std.testing.allocator, io);

    var rebound = try SiteRuntime.bind(std.testing.allocator, io, "proxy.cfg", cfg, 64);
    rebound.unbind(std.testing.allocator, io);
}

test "zix zixer: site runtime, http1 static-only site serves without upstreams" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cfg = site_cfg.SiteCfg{ .engine = .HTTP1, .ip = "127.0.0.1", .port = 39882, .public_dir = "/var/www/pages" };

    var runtime = try SiteRuntime.bind(std.testing.allocator, io, "static.cfg", cfg, 64);
    try std.testing.expect(runtime.listener == .proxy_edge);

    runtime.unbind(std.testing.allocator, io);
}

test "zix zixer: site runtime, http3 engine also takes the udp path" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cfg = site_cfg.SiteCfg{ .engine = .HTTP3, .ip = "127.0.0.1", .port = 39863 };

    var runtime = try SiteRuntime.bind(std.testing.allocator, io, "pages.cfg", cfg, 64);
    try std.testing.expect(runtime.listener == .udp);

    runtime.unbind(std.testing.allocator, io);
}

test "zix zixer: site runtime, companion port only for tls acme sites off 80" {
    const tls_acme = site_cfg.SiteCfg{ .engine = .HTTP1, .port = 443, .tls = true, .acme_webroot = "/var/www/acme" };
    try std.testing.expectEqual(@as(?u16, 80), companionPort(&tls_acme));

    const tls_relay = site_cfg.SiteCfg{ .engine = .HTTP1, .port = 443, .tls = true, .acme_proxy = .{ .host = "127.0.0.1", .port = 9080 } };
    try std.testing.expectEqual(@as(?u16, 80), companionPort(&tls_relay));

    const tls_only = site_cfg.SiteCfg{ .engine = .HTTP1, .port = 443, .tls = true };
    try std.testing.expectEqual(@as(?u16, null), companionPort(&tls_only));

    const cleartext = site_cfg.SiteCfg{ .engine = .HTTP1, .port = 80, .acme_webroot = "/var/www/acme" };
    try std.testing.expectEqual(@as(?u16, null), companionPort(&cleartext));

    const tls_on_80 = site_cfg.SiteCfg{ .engine = .HTTP1, .port = 80, .tls = true, .acme_webroot = "/var/www/acme" };
    try std.testing.expectEqual(@as(?u16, null), companionPort(&tls_on_80));
}

test "zix zixer: site runtime, owns port covers the main listener" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cfg = site_cfg.SiteCfg{ .engine = .HTTP1, .ip = "127.0.0.1", .port = 39896 };

    var runtime = try SiteRuntime.bind(std.testing.allocator, io, "own.cfg", cfg, 64);
    try std.testing.expect(runtime.ownsPort(39896));
    try std.testing.expect(!runtime.ownsPort(80));
    try std.testing.expect(runtime.challenge == null);

    runtime.unbind(std.testing.allocator, io);
}

/// True when this process may bind the privileged http-01 port. Probed
/// with raw syscalls: a failing privileged bind through std prints the
/// unexpected-errno trace in debug builds, the probe keeps unprivileged
/// runs silent.
fn canBindPort80() bool {
    const linux = std.os.linux;

    const fd_raw = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (@as(isize, @bitCast(fd_raw)) < 0) return false;
    const fd: i32 = @intCast(fd_raw);
    defer _ = linux.close(fd);

    const addr = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, 80),
        .addr = std.mem.nativeToBig(u32, 0x7F00_0001),
    };

    return linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)) == 0;
}

test "zix zixer: site runtime, tls acme site binds the port 80 companion" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;
    if (!canBindPort80()) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cfg = site_cfg.SiteCfg{
        .engine = .HTTP1,
        .ip = "127.0.0.1",
        .port = 39897,
        .tls = true,
        .tls_cert = "examples/certs/ecdsa_p256_cert.pem",
        .tls_key = "examples/certs/ecdsa_p256_key.pem",
        .acme_webroot = "/var/www/acme",
        .public_dir = "/var/www/pages",
    };

    var runtime = SiteRuntime.bind(std.testing.allocator, io, "tls.cfg", cfg, 64) catch |err| {
        // port 80 is privileged: without the capability (or as non-root)
        // the companion bind cannot be exercised, skip explicitly. The
        // EACCES from a privileged bind surfaces as Unexpected through the
        // std listen error mapping.
        if (err == error.AccessDenied or err == error.PermissionDenied or err == error.AddressInUse or err == error.Unexpected) return error.SkipZigTest;

        return err;
    };

    try std.testing.expect(runtime.challenge != null);
    try std.testing.expect(runtime.ownsPort(39897));
    try std.testing.expect(runtime.ownsPort(80));

    runtime.unbind(std.testing.allocator, io);
}
