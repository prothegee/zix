//! zixer site runtime: the bound listener a started site owns

const std = @import("std");

const site_cfg = @import("site_cfg.zig");

/// One started site inside the daemon.
///
/// Note:
/// - Phase 2 binds and holds the socket, so the port is owned and a collision
///   surfaces at start time. The engine loop attaches in a later phase.
pub const SiteRuntime = struct {
    name: []const u8,
    engine: site_cfg.Engine,
    port: u16,
    listener: Listener,

    /// Bound socket by transport: tcp engines listen, udp engines bind a
    /// datagram socket.
    const Listener = union(enum) {
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

        // Reuse flags stay off on purpose: a second bind on the same ip:port
        // must fail with AddressInUse, that collision check is the point here.
        const listener: Listener = switch (engine) {
            .HTTP1, .HTTP2, .GRPC => .{ .tcp = try addr.listen(io, .{ .kernel_backlog = kernel_backlog }) },
            .HTTP3, .UDP => .{ .udp = try addr.bind(io, .{ .mode = .dgram, .protocol = .udp }) },
        };

        return .{ .name = owned_name, .engine = engine, .port = port, .listener = listener };
    }

    /// Close the listener and release the name. The runtime is dead after.
    pub fn unbind(runtime: *SiteRuntime, allocator: std.mem.Allocator, io: std.Io) void {
        switch (runtime.listener) {
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

test "zix zixer: site runtime, tcp bind owns the port and unbind frees it" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cfg = site_cfg.SiteCfg{ .engine = .HTTP1, .ip = "127.0.0.1", .port = 39861 };

    var first = try SiteRuntime.bind(std.testing.allocator, io, "a.cfg", cfg, 64);
    try std.testing.expectEqualStrings("a.cfg", first.name);
    try std.testing.expectEqual(@as(u16, 39861), first.port);

    try std.testing.expectError(error.AddressInUse, SiteRuntime.bind(std.testing.allocator, io, "b.cfg", cfg, 64));

    first.unbind(std.testing.allocator, io);

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

test "zix zixer: site runtime, http3 engine also takes the udp path" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cfg = site_cfg.SiteCfg{ .engine = .HTTP3, .ip = "127.0.0.1", .port = 39863 };

    var runtime = try SiteRuntime.bind(std.testing.allocator, io, "pages.cfg", cfg, 64);
    try std.testing.expect(runtime.listener == .udp);

    runtime.unbind(std.testing.allocator, io);
}
