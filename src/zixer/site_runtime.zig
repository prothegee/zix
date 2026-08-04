//! zixer site runtime: the bound listener a started site owns

const std = @import("std");

const site_cfg = @import("site_cfg.zig");
const site_serve = @import("site_serve.zig");

/// One started site inside the daemon.
///
/// Note:
/// - An http1 site with upstreams serves the proxy loop (phase 3). Every
///   other engine binds and holds its socket, so the port is owned and a
///   collision surfaces at start time, the loop attaches in its own phase.
pub const SiteRuntime = struct {
    name: []const u8,
    engine: site_cfg.Engine,
    port: u16,
    listener: Listener,

    /// What the site holds: a serving proxy edge, or the bare bound socket
    /// (tcp engines listen, udp engines bind a datagram socket).
    const Listener = union(enum) {
        http1_proxy: *site_serve.ServeState,
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
        const listener: Listener = switch (engine) {
            .HTTP1, .HTTP2, .GRPC => blk: {
                var server = try addr.listen(io, .{ .reuse_address = true, .kernel_backlog = kernel_backlog });

                if (engine == .HTTP1 and cfg.upstreams.len > 0) {
                    const state = site_serve.ServeState.create(allocator, io, server, cfg.upstreams, cfg.ip, port) catch |err| {
                        server.deinit(io);
                        return err;
                    };

                    break :blk .{ .http1_proxy = state };
                }

                break :blk .{ .tcp = server };
            },
            .HTTP3, .UDP => .{ .udp = try addr.bind(io, .{ .mode = .dgram, .protocol = .udp }) },
        };

        return .{ .name = owned_name, .engine = engine, .port = port, .listener = listener };
    }

    /// Stop any serve loop, close the listener, release the name.
    pub fn unbind(runtime: *SiteRuntime, allocator: std.mem.Allocator, io: std.Io) void {
        switch (runtime.listener) {
            .http1_proxy => |state| state.shutdown(),
            .tcp => |*server| server.deinit(io),
            .udp => |socket| socket.close(io),
        }

        allocator.free(runtime.name);
    }
};

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
    try std.testing.expect(runtime.listener == .http1_proxy);

    runtime.unbind(std.testing.allocator, io);

    var rebound = try SiteRuntime.bind(std.testing.allocator, io, "proxy.cfg", cfg, 64);
    rebound.unbind(std.testing.allocator, io);
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
