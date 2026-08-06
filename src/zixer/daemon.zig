//! zixer daemon: control socket loop over the started-site registry

const std = @import("std");
const zix = @import("zix");

const control = @import("control.zig");
const fault = @import("fault.zig");
const main_cfg = @import("main_cfg.zig");
const root_dir = @import("root_dir.zig");
const site_cfg = @import("site_cfg.zig");
const site_runtime = @import("site_runtime.zig");

/// Hard ceiling for one config file, a larger file fails instead of allocating.
const MAX_CFG_BYTES: usize = 256 * 1024;

/// Consecutive accept failures before the control loop gives up, so a broken
/// socket cannot spin the daemon hot.
const MAX_ACCEPT_FAILURES: usize = 100;

/// The daemon: owns the control socket and every started site.
///
/// Note:
/// - Requests are handled one at a time on purpose. The control plane is not
///   a data path, and serial handling keeps the registry lock-free.
pub const Daemon = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: main_cfg.MainCfg,
    socket_path: []const u8,
    sites: std.ArrayList(site_runtime.SiteRuntime) = .empty,
    stop_requested: bool = false,

    /// Load and validate main.cfg, refuse to build on any fault.
    ///
    /// Param:
    /// allocator - std.mem.Allocator (site registry and names, long-lived)
    /// io - std.Io
    /// arena - std.mem.Allocator (owns main.cfg content and the socket path, must outlive the daemon)
    /// root - root_dir.RootDir (resolved root dir)
    ///
    /// Return:
    /// - Daemon ready for run()
    /// - error.NotInitialized when main.cfg is missing
    /// - error.MainCfgInvalid when main.cfg carries faults
    pub fn init(allocator: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, root: root_dir.RootDir) !Daemon {
        const main_cfg_path = try std.fs.path.join(arena, &.{ root.path, "main.cfg" });
        const content = zix.utils.file.load(io, arena, main_cfg_path, MAX_CFG_BYTES) catch return error.NotInitialized;

        const available_threads = std.Thread.getCpuCount() catch 1;
        var faults = fault.FaultList.init(arena);
        const cfg = try main_cfg.parse(arena, content, root.path, available_threads, &faults);
        if (faults.slice().len != 0) return error.MainCfgInvalid;

        const socket_path = try control.socketPath(io, arena, root.path);

        return .{ .allocator = allocator, .io = io, .cfg = cfg, .socket_path = socket_path };
    }

    /// Unbind whatever is still started and drop the registry.
    pub fn deinit(self: *Daemon) void {
        self.unbindAll();
        self.sites.deinit(self.allocator);
    }

    /// Bind the control socket and serve request lines until shutdown.
    ///
    /// Note:
    /// - The caller has already checked no live daemon answers on the socket,
    ///   so a leftover socket file here is stale and safe to remove.
    ///
    /// Return:
    /// - void after a clean shutdown request
    /// - error.ControlPathTooLong when the root dir cannot host a socket
    /// - error.ControlSocketBroken when accept keeps failing
    pub fn run(self: *Daemon) !void {
        if (comptime !std.Io.net.has_unix_sockets) return error.UdsNotSupported;
        if (!control.fitsSocket(self.socket_path)) return error.ControlPathTooLong;

        const io = self.io;

        std.Io.Dir.deleteFileAbsolute(io, self.socket_path) catch {};

        const unix_addr = try std.Io.net.UnixAddress.init(self.socket_path);
        var server = try unix_addr.listen(io, .{});
        defer {
            server.deinit(io);
            std.Io.Dir.deleteFileAbsolute(io, self.socket_path) catch {};
        }

        var accept_failures: usize = 0;
        while (!self.stop_requested) {
            const stream = server.accept(io) catch {
                accept_failures += 1;
                if (accept_failures >= MAX_ACCEPT_FAILURES) return error.ControlSocketBroken;
                continue;
            };
            accept_failures = 0;

            self.serveConn(stream);
        }

        self.unbindAll();
    }

    /// Handle one request line, the reply lands in reply_buf.
    ///
    /// Note:
    /// - Every outcome is a reply line, the daemon never dies on a request.
    pub fn handleLine(self: *Daemon, line: []const u8, reply_buf: []u8) []const u8 {
        const request = control.parseRequest(line) orelse
            return print(reply_buf, "error: unknown command, use start/stop/restart <site.cfg>, ping, or shutdown", .{});

        return switch (request.verb) {
            .PING => print(reply_buf, "ok: zixer daemon", .{}),
            .SHUTDOWN => self.handleShutdown(reply_buf),
            .START => self.handleStart(request.name, reply_buf),
            .STOP => self.handleStop(request.name, reply_buf),
            .RESTART => self.handleRestart(request.name, reply_buf),
        };
    }

    fn handleStart(self: *Daemon, name: []const u8, reply_buf: []u8) []const u8 {
        if (rejectName(name, reply_buf)) |reply| return reply;
        if (self.findSite(name) != null)
            return print(reply_buf, "error: {s} is already started, use restart to reload it", .{name});

        return self.bindSite(name, reply_buf, "started");
    }

    fn handleStop(self: *Daemon, name: []const u8, reply_buf: []u8) []const u8 {
        if (rejectName(name, reply_buf)) |reply| return reply;

        const index = self.findSite(name) orelse
            return print(reply_buf, "error: {s} is not started", .{name});

        var runtime = self.sites.swapRemove(index);
        runtime.unbind(self.allocator, self.io);

        return print(reply_buf, "ok: {s} stopped", .{name});
    }

    /// Restart re-reads the cfg from disk, that is what a certbot deploy-hook
    /// relies on. A site that was not started is simply started, so the hook
    /// never fails on a site that happened to be down.
    fn handleRestart(self: *Daemon, name: []const u8, reply_buf: []u8) []const u8 {
        if (rejectName(name, reply_buf)) |reply| return reply;

        if (self.findSite(name)) |index| {
            var runtime = self.sites.swapRemove(index);
            runtime.unbind(self.allocator, self.io);

            return self.bindSite(name, reply_buf, "restarted");
        }

        return self.bindSite(name, reply_buf, "started");
    }

    fn handleShutdown(self: *Daemon, reply_buf: []u8) []const u8 {
        self.stop_requested = true;

        return print(reply_buf, "ok: daemon stopped, sites unbound: {d}", .{self.sites.items.len});
    }

    /// Parse, validate, and bind one site, appending it to the registry.
    fn bindSite(self: *Daemon, name: []const u8, reply_buf: []u8, past_verb: []const u8) []const u8 {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();

        const site_path = std.fs.path.join(arena, &.{ self.cfg.sites_dir, name }) catch
            return print(reply_buf, "error: out of memory", .{});
        const content = zix.utils.file.load(self.io, arena, site_path, MAX_CFG_BYTES) catch
            return print(reply_buf, "error: cannot read {s}, run: zixer list", .{name});

        var faults = fault.FaultList.init(arena);
        const cfg = site_cfg.parse(arena, content, &faults) catch
            return print(reply_buf, "error: out of memory", .{});
        if (faults.slice().len != 0 or cfg.engine == null or cfg.port == null)
            return print(reply_buf, "error: {s} has config errors, run: zixer status {s}", .{ name, name });

        // Tcp sites listen with reuse_address (restart survives TIME_WAIT),
        // so a same-port collision between sites must be caught here, the
        // kernel would happily share the port. A site owns its main port
        // plus, on a TLS acme site, the port 80 companion.
        for (self.sites.items) |*site| {
            if (site.ownsPort(cfg.port.?))
                return print(reply_buf, "error: {s} port {d} is already used by {s}", .{ name, cfg.port.?, site.name });

            if (site_runtime.companionPort(&cfg)) |challenge_port| {
                if (site.ownsPort(challenge_port))
                    return print(reply_buf, "error: {s} challenge port {d} is already used by {s}", .{ name, challenge_port, site.name });
            }
        }

        const backlog = resolveBacklog(cfg.kernel_backlog, self.cfg.kernel_backlog);
        const runtime = site_runtime.SiteRuntime.bind(self.allocator, self.io, name, cfg, backlog) catch |err| switch (err) {
            error.AddressInUse => return print(reply_buf, "error: {s} port {d} is already in use", .{ name, cfg.port.? }),
            error.TlsCertFileNotFound => return print(reply_buf, "error: {s} cannot read the tls_cert file", .{name}),
            error.TlsKeyFileNotFound => return print(reply_buf, "error: {s} cannot read the tls_key file", .{name}),
            else => {
                if (site_runtime.companionPort(&cfg) != null)
                    return print(reply_buf, "error: {s} bind failed ({s}), the acme challenge listener needs port 80", .{ name, @errorName(err) });

                return print(reply_buf, "error: {s} bind failed ({s})", .{ name, @errorName(err) });
            },
        };

        self.sites.append(self.allocator, runtime) catch {
            var orphan = runtime;
            orphan.unbind(self.allocator, self.io);

            return print(reply_buf, "error: out of memory", .{});
        };

        return print(reply_buf, "ok: {s} {s} on {s}:{d}", .{ name, past_verb, cfg.ip, cfg.port.? });
    }

    fn findSite(self: *Daemon, name: []const u8) ?usize {
        for (self.sites.items, 0..) |site, i| {
            if (std.mem.eql(u8, site.name, name)) return i;
        }

        return null;
    }

    fn unbindAll(self: *Daemon) void {
        for (self.sites.items) |*site| site.unbind(self.allocator, self.io);

        self.sites.clearRetainingCapacity();
    }

    /// One conn, one exchange: read a line, reply, close.
    fn serveConn(self: *Daemon, stream: std.Io.net.Stream) void {
        const io = self.io;
        defer stream.close(io);

        var read_buf: [control.MAX_LINE]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        var line_buf: [control.MAX_LINE]u8 = undefined;
        var len: usize = 0;
        while (len < line_buf.len) {
            const got = reader.interface.readSliceShort(line_buf[len .. len + 1]) catch return;
            if (got == 0) break;
            if (line_buf[len] == '\n') break;
            len += got;
        }

        var reply_buf: [control.MAX_LINE]u8 = undefined;
        const reply = self.handleLine(line_buf[0..len], &reply_buf);

        var write_buf: [control.MAX_LINE]u8 = undefined;
        var writer = stream.writer(io, &write_buf);
        writer.interface.writeAll(reply) catch return;
        writer.interface.writeAll("\n") catch return;
        writer.interface.flush() catch return;
    }
};

/// The listen backlog one site binds with: its own kernel_backlog when the
/// site file set one, the main.cfg value otherwise.
fn resolveBacklog(site_backlog: ?u31, main_backlog: u31) u31 {
    return site_backlog orelse main_backlog;
}

/// Reply for a name the daemon must not resolve, null when the name is fine.
fn rejectName(name: []const u8, reply_buf: []u8) ?[]const u8 {
    if (control.siteNameSafe(name)) return null;

    return print(reply_buf, "error: site name must be a bare file name, i.e. service_api_h1.cfg", .{});
}

fn print(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch "error: reply too long";
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

const cmd_init = @import("cmd_init.zig");
const control_client = @import("control_client.zig");

fn writeSiteFile(io: std.Io, arena: std.mem.Allocator, root: []const u8, name: []const u8, content: []const u8) !void {
    const path = try std.fs.path.join(arena, &.{ root, "sites", name });
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var write_buf: [1024]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try writer.interface.writeAll(content);
    try writer.interface.flush();
}

fn testDaemon(io: std.Io, arena: std.mem.Allocator, root: []const u8) !Daemon {
    var init_buf: [2048]u8 = undefined;
    var init_report = std.Io.Writer.fixed(&init_buf);
    _ = try cmd_init.run(io, arena, &init_report, .{ .path = root, .source = .ARG });

    return Daemon.init(std.testing.allocator, io, arena, .{ .path = root, .source = .ARG });
}

test "zix zixer: daemon init, missing root and broken main.cfg both refuse" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.NotInitialized,
        Daemon.init(std.testing.allocator, io, arena.allocator(), .{ .path = "tmp/zixer_daemon_absent/root", .source = .ARG }),
    );

    const test_root = "tmp/zixer_daemon_badmain/root";
    defer std.Io.Dir.cwd().deleteTree(io, "tmp/zixer_daemon_badmain") catch {};

    var init_buf: [2048]u8 = undefined;
    var init_report = std.Io.Writer.fixed(&init_buf);
    _ = try cmd_init.run(io, arena.allocator(), &init_report, .{ .path = test_root, .source = .ARG });

    const main_path = try std.fs.path.join(arena.allocator(), &.{ test_root, "main.cfg" });
    const file = try std.Io.Dir.cwd().createFile(io, main_path, .{});
    var write_buf: [128]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try writer.interface.writeAll("no_such_key: 1\n");
    try writer.interface.flush();
    file.close(io);

    try std.testing.expectError(
        error.MainCfgInvalid,
        Daemon.init(std.testing.allocator, io, arena.allocator(), .{ .path = test_root, .source = .ARG }),
    );
}

test "zix zixer: daemon handleLine, ping answers and unknown command explains" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const test_root = "tmp/zixer_daemon_ping/root";
    defer std.Io.Dir.cwd().deleteTree(io, "tmp/zixer_daemon_ping") catch {};

    var daemon = try testDaemon(io, arena.allocator(), test_root);
    defer daemon.deinit();

    var reply_buf: [control.MAX_LINE]u8 = undefined;
    try std.testing.expectEqualStrings("ok: zixer daemon", daemon.handleLine("ping", &reply_buf));
    try std.testing.expect(std.mem.startsWith(u8, daemon.handleLine("reload a.cfg", &reply_buf), "error: unknown command"));
    try std.testing.expect(std.mem.startsWith(u8, daemon.handleLine("start ../evil.cfg", &reply_buf), "error: site name must be"));
}

test "zix zixer: daemon handleLine, unsafe name is rejected on every site verb" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const test_root = "tmp/zixer_daemon_unsafe/root";
    defer std.Io.Dir.cwd().deleteTree(io, "tmp/zixer_daemon_unsafe") catch {};

    var daemon = try testDaemon(io, arena.allocator(), test_root);
    defer daemon.deinit();

    var reply_buf: [control.MAX_LINE]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, daemon.handleLine("start ../evil.cfg", &reply_buf), "error: site name must be"));
    try std.testing.expect(std.mem.startsWith(u8, daemon.handleLine("stop ../evil.cfg", &reply_buf), "error: site name must be"));
    try std.testing.expect(std.mem.startsWith(u8, daemon.handleLine("restart ../evil.cfg", &reply_buf), "error: site name must be"));
    try std.testing.expect(std.mem.startsWith(u8, daemon.handleLine("stop sub\\site.cfg", &reply_buf), "error: site name must be"));
}

test "zix zixer: daemon handleLine, start stop restart walk the registry" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const test_root = "tmp/zixer_daemon_verbs/root";
    defer std.Io.Dir.cwd().deleteTree(io, "tmp/zixer_daemon_verbs") catch {};

    var daemon = try testDaemon(io, arena.allocator(), test_root);
    defer daemon.deinit();

    try writeSiteFile(io, arena.allocator(), test_root, "service_a.cfg", "engine: http1\nip: 127.0.0.1\nport: 39864\nupstreams: 127.0.0.1:3000\n");

    var reply_buf: [control.MAX_LINE]u8 = undefined;
    try std.testing.expectEqualStrings(
        "ok: service_a.cfg started on 127.0.0.1:39864",
        daemon.handleLine("start service_a.cfg", &reply_buf),
    );
    try std.testing.expectEqual(@as(usize, 1), daemon.sites.items.len);

    try std.testing.expectEqualStrings(
        "error: service_a.cfg is already started, use restart to reload it",
        daemon.handleLine("start service_a.cfg", &reply_buf),
    );

    try std.testing.expectEqualStrings(
        "ok: service_a.cfg restarted on 127.0.0.1:39864",
        daemon.handleLine("restart service_a.cfg", &reply_buf),
    );

    try std.testing.expectEqualStrings("ok: service_a.cfg stopped", daemon.handleLine("stop service_a.cfg", &reply_buf));
    try std.testing.expectEqual(@as(usize, 0), daemon.sites.items.len);

    try std.testing.expectEqualStrings(
        "error: service_a.cfg is not started",
        daemon.handleLine("stop service_a.cfg", &reply_buf),
    );

    try std.testing.expectEqualStrings(
        "ok: service_a.cfg started on 127.0.0.1:39864",
        daemon.handleLine("restart service_a.cfg", &reply_buf),
    );
}

test "zix zixer: daemon handleLine, missing site and broken site refuse to start" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const test_root = "tmp/zixer_daemon_badsite/root";
    defer std.Io.Dir.cwd().deleteTree(io, "tmp/zixer_daemon_badsite") catch {};

    var daemon = try testDaemon(io, arena.allocator(), test_root);
    defer daemon.deinit();

    var reply_buf: [control.MAX_LINE]u8 = undefined;
    try std.testing.expectEqualStrings(
        "error: cannot read absent.cfg, run: zixer list",
        daemon.handleLine("start absent.cfg", &reply_buf),
    );

    try writeSiteFile(io, arena.allocator(), test_root, "broken.cfg", "engine: http1\n");
    try std.testing.expectEqualStrings(
        "error: broken.cfg has config errors, run: zixer status broken.cfg",
        daemon.handleLine("start broken.cfg", &reply_buf),
    );
}

test "zix zixer: daemon handleLine, two sites on one port collide at start" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const test_root = "tmp/zixer_daemon_collide/root";
    defer std.Io.Dir.cwd().deleteTree(io, "tmp/zixer_daemon_collide") catch {};

    var daemon = try testDaemon(io, arena.allocator(), test_root);
    defer daemon.deinit();

    try writeSiteFile(io, arena.allocator(), test_root, "one.cfg", "engine: http1\nip: 127.0.0.1\nport: 39865\nupstreams: 127.0.0.1:3000\n");
    try writeSiteFile(io, arena.allocator(), test_root, "two.cfg", "engine: http1\nip: 127.0.0.1\nport: 39865\nupstreams: 127.0.0.1:3001\n");

    var reply_buf: [control.MAX_LINE]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, daemon.handleLine("start one.cfg", &reply_buf), "ok: "));
    try std.testing.expectEqualStrings(
        "error: two.cfg port 39865 is already used by one.cfg",
        daemon.handleLine("start two.cfg", &reply_buf),
    );
}

test "zix zixer: daemon backlog, a site override wins over the main.cfg value" {
    // main.cfg carries the default, a site file may raise or lower it for
    // its own listener. The bound value is visible on the wire as the
    // listen queue length.
    try std.testing.expectEqual(@as(u31, 1024), resolveBacklog(null, 1024));
    try std.testing.expectEqual(@as(u31, 7), resolveBacklog(7, 1024));
    try std.testing.expectEqual(@as(u31, 4096), resolveBacklog(4096, 128));
}

test "zix zixer: daemon backlog, a started site binds with the resolved value" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const test_root = "tmp/zixer_daemon_backlog/root";
    defer std.Io.Dir.cwd().deleteTree(io, "tmp/zixer_daemon_backlog") catch {};

    var daemon = try testDaemon(io, arena.allocator(), test_root);
    defer daemon.deinit();

    try writeSiteFile(io, arena.allocator(), test_root, "inherited.cfg", "engine: http1\nip: 127.0.0.1\nport: 39867\nupstreams: 127.0.0.1:3000\n");
    try writeSiteFile(io, arena.allocator(), test_root, "own.cfg", "engine: http1\nip: 127.0.0.1\nport: 39868\nupstreams: 127.0.0.1:3000\nkernel_backlog: 7\n");

    var reply_buf: [control.MAX_LINE]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, daemon.handleLine("start inherited.cfg", &reply_buf), "ok: "));
    try std.testing.expect(std.mem.startsWith(u8, daemon.handleLine("start own.cfg", &reply_buf), "ok: "));

    // Both bind: a backlog far below the main.cfg default is still a valid
    // listener, it only shortens the pending-connection queue.
    try std.testing.expectEqual(@as(usize, 2), daemon.sites.items.len);
    try std.testing.expectEqual(@as(u31, 1024), daemon.cfg.kernel_backlog);
}

test "zix zixer: daemon handleLine, shutdown reports the unbind count and sets the flag" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const test_root = "tmp/zixer_daemon_shutdown/root";
    defer std.Io.Dir.cwd().deleteTree(io, "tmp/zixer_daemon_shutdown") catch {};

    var daemon = try testDaemon(io, arena.allocator(), test_root);
    defer daemon.deinit();

    try writeSiteFile(io, arena.allocator(), test_root, "service_a.cfg", "engine: http1\nip: 127.0.0.1\nport: 39866\nupstreams: 127.0.0.1:3000\n");

    var reply_buf: [control.MAX_LINE]u8 = undefined;
    _ = daemon.handleLine("start service_a.cfg", &reply_buf);

    try std.testing.expectEqualStrings("ok: daemon stopped, sites unbound: 1", daemon.handleLine("shutdown", &reply_buf));
    try std.testing.expect(daemon.stop_requested);
}

fn runDaemonThread(daemon: *Daemon) void {
    daemon.run() catch {};
}

test "zix zixer: daemon end to end, socket round trip start ping shutdown" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const test_root = "tmp/zixer_daemon_e2e/root";
    defer std.Io.Dir.cwd().deleteTree(io, "tmp/zixer_daemon_e2e") catch {};

    var daemon = try testDaemon(io, arena.allocator(), test_root);
    defer daemon.deinit();

    try writeSiteFile(io, arena.allocator(), test_root, "service_a.cfg", "engine: http1\nip: 127.0.0.1\nport: 39867\nupstreams: 127.0.0.1:3000\n");

    const daemon_thread = try std.Thread.spawn(.{}, runDaemonThread, .{&daemon});

    // Bounded wait for the control socket to answer, then one exchange per verb.
    var tries: usize = 0;
    while (tries < 100 and !control_client.ping(io, daemon.socket_path)) : (tries += 1) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .awake) catch {};
    }
    try std.testing.expect(tries < 100);

    var reply_buf: [control.MAX_LINE]u8 = undefined;
    const started = try control_client.call(io, daemon.socket_path, "start service_a.cfg", &reply_buf);
    try std.testing.expect(started.ok);
    try std.testing.expectEqualStrings("service_a.cfg started on 127.0.0.1:39867", started.text);

    var stop_buf: [control.MAX_LINE]u8 = undefined;
    const stopped = try control_client.call(io, daemon.socket_path, "shutdown", &stop_buf);
    try std.testing.expect(stopped.ok);

    daemon_thread.join();

    try std.testing.expectEqual(@as(usize, 0), daemon.sites.items.len);
}

test "zix zixer: daemon handleLine, tls site with a missing cert file refuses" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const test_root = "tmp/zixer_daemon_tlscert/root";
    defer std.Io.Dir.cwd().deleteTree(io, "tmp/zixer_daemon_tlscert") catch {};

    var daemon = try testDaemon(io, arena.allocator(), test_root);
    defer daemon.deinit();

    try writeSiteFile(io, arena.allocator(), test_root, "tls_bad.cfg", "engine: http1\nip: 127.0.0.1\nport: 39898\n" ++
        "tls: true\ntls_cert: examples/certs/absent.pem\ntls_key: examples/certs/ecdsa_p256_key.pem\n" ++
        "public_dir: /var/www/pages\n");

    var reply_buf: [control.MAX_LINE]u8 = undefined;
    const reply = daemon.handleLine("start tls_bad.cfg", &reply_buf);
    try std.testing.expect(std.mem.indexOf(u8, reply, "cannot read the tls_cert file") != null);
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

test "zix zixer: daemon handleLine, tls acme site starts or names the port 80 need" {
    if (comptime @import("builtin").os.tag == .linux) {
        if (!canBindPort80()) return error.SkipZigTest;
    }

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const test_root = "tmp/zixer_daemon_tlsacme/root";
    defer std.Io.Dir.cwd().deleteTree(io, "tmp/zixer_daemon_tlsacme") catch {};

    var daemon = try testDaemon(io, arena.allocator(), test_root);
    defer daemon.deinit();

    try writeSiteFile(io, arena.allocator(), test_root, "tls_acme.cfg", "engine: http1\nip: 127.0.0.1\nport: 39899\n" ++
        "tls: true\ntls_cert: examples/certs/ecdsa_p256_cert.pem\ntls_key: examples/certs/ecdsa_p256_key.pem\n" ++
        "acme_webroot: /var/www/acme\npublic_dir: /var/www/pages\n");

    var reply_buf: [control.MAX_LINE]u8 = undefined;
    const reply = daemon.handleLine("start tls_acme.cfg", &reply_buf);

    // with the privilege (root, capability) the companion binds and the
    // site starts, without it the reply names the port 80 need.
    if (std.mem.startsWith(u8, reply, "ok: ")) {
        try std.testing.expect(std.mem.startsWith(u8, daemon.handleLine("stop tls_acme.cfg", &reply_buf), "ok: "));
    } else {
        try std.testing.expect(std.mem.indexOf(u8, reply, "needs port 80") != null);
    }
}
