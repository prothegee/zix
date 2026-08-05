//! zixer acme companion listener: cleartext challenge port for a TLS site

const std = @import("std");

const acme_challenge = @import("acme_challenge.zig");
const http1_proxy = @import("http1_proxy.zig");
const site_cfg = @import("site_cfg.zig");

/// Consecutive accept failures before the loop gives up.
const MAX_ACCEPT_FAILURES: usize = 100;

/// The bound challenge listener a TLS site with acme keys owns beside its
/// main listener. It serves exactly two things: the challenge path from
/// the site's acme config, and a 301 to https for everything else.
///
/// Note:
/// - The CA validates http-01 on port 80 only (rfc 8555 8.3), so the
///   production bind is always port 80. Tests bind high ports.
pub const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    server: std.Io.net.Server,
    webroot: ?[]const u8,
    relay: ?site_cfg.Upstream,
    https_port: u16,
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    /// Live connection tasks. A concurrent group member releases its
    /// resources when the task returns, shutdown cancels the stragglers.
    conns: std.Io.Group = .init,
    wake_ip: []const u8,
    port: u16,

    /// Build the companion state and start its accept thread.
    ///
    /// Note:
    /// - server is moved in here, shutdown() closes it.
    /// - webroot and the relay host are duped, the caller's arena may go.
    ///
    /// Param:
    /// allocator - std.mem.Allocator (state and strings, long-lived)
    /// io - std.Io (must outlive the state)
    /// server - std.Io.net.Server (bound cleartext challenge listener)
    /// webroot - ?[]const u8 (the site's acme_webroot)
    /// relay - ?site_cfg.Upstream (the site's acme_proxy)
    /// ip - []const u8 (listen ip, for the shutdown wake)
    /// port - u16 (the bound challenge port)
    /// https_port - u16 (the site's TLS port, redirect target)
    ///
    /// Return:
    /// - *State with the accept thread running
    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        server: std.Io.net.Server,
        webroot: ?[]const u8,
        relay: ?site_cfg.Upstream,
        ip: []const u8,
        port: u16,
        https_port: u16,
    ) !*State {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);

        const owned_webroot: ?[]const u8 = if (webroot) |inner| try allocator.dupe(u8, inner) else null;
        errdefer if (owned_webroot) |inner| allocator.free(inner);
        var owned_relay = relay;
        if (relay) |inner| owned_relay.?.host = try allocator.dupe(u8, inner.host);
        errdefer if (owned_relay) |inner| allocator.free(inner.host);
        const wake_ip = try allocator.dupe(u8, ip);
        errdefer allocator.free(wake_ip);

        state.* = .{
            .allocator = allocator,
            .io = io,
            .server = server,
            .webroot = owned_webroot,
            .relay = owned_relay,
            .https_port = https_port,
            .wake_ip = wake_ip,
            .port = port,
        };

        state.thread = try std.Thread.spawn(.{}, acceptLoop, .{state});

        return state;
    }

    /// Stop the accept thread, cancel the connection tasks, close the
    /// listener, release everything.
    pub fn shutdown(state: *State) void {
        const io = state.io;

        state.stop.store(true, .release);
        wake(io, state.wake_ip, state.port);
        if (state.thread) |thread| thread.join();
        state.conns.cancel(io);

        state.server.deinit(io);
        if (state.webroot) |inner| state.allocator.free(inner);
        if (state.relay) |inner| state.allocator.free(inner.host);
        state.allocator.free(state.wake_ip);

        const allocator = state.allocator;
        allocator.destroy(state);
    }
};

fn acceptLoop(state: *State) void {
    const io = state.io;

    const proxy = http1_proxy.Proxy{
        .io = io,
        .acme = .{ .webroot = state.webroot, .relay = state.relay },
        .redirect_https = state.https_port,
    };

    var accept_failures: usize = 0;
    while (!state.stop.load(.acquire)) {
        const stream = state.server.accept(io) catch {
            if (state.stop.load(.acquire)) return;

            accept_failures += 1;
            if (accept_failures >= MAX_ACCEPT_FAILURES) return;
            continue;
        };
        accept_failures = 0;

        if (state.stop.load(.acquire)) {
            stream.close(io);
            return;
        }

        const task = ConnTask{ .proxy = proxy, .stream = stream };
        state.conns.concurrent(io, serveTask, .{task}) catch serveTask(task);
    }
}

const ConnTask = struct {
    proxy: http1_proxy.Proxy,
    stream: std.Io.net.Stream,
};

fn serveTask(task: ConnTask) void {
    http1_proxy.serveConn(&task.proxy, task.stream);
}

/// Connect-and-close against the challenge port so a blocked accept
/// returns. A wildcard listen ip is reached through loopback.
fn wake(io: std.Io, ip: []const u8, port: u16) void {
    const target = if (std.mem.eql(u8, ip, "0.0.0.0"))
        "127.0.0.1"
    else if (std.mem.eql(u8, ip, "::"))
        "::1"
    else
        ip;

    const addr = std.Io.net.IpAddress.parse(target, port) catch return;
    const stream = addr.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch return;
    stream.close(io);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

const testing = std.testing;

fn writeFixture(dir: std.Io.Dir, name: []const u8, data: []const u8) void {
    dir.writeFile(testing.io, .{ .sub_path = name, .data = data }) catch @panic("fixture write failed");
}

/// The tmp dir path relative to the test cwd, printed into buf.
fn fixtureRoot(buf: []u8, tmp: *const testing.TmpDir) []const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;
}

fn fetch(io: std.Io, port: u16, request: []const u8, reply_buf: []u8) !usize {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    const stream = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);

    var write_buf: [512]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll(request);
    try writer.interface.flush();

    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var len: usize = 0;
    while (len < reply_buf.len) {
        const got = reader.interface.readSliceShort(reply_buf[len .. len + 1]) catch break;
        if (got == 0) break;

        len += got;
    }

    return len;
}

test "zix zixer: acme listener, challenge answers and the rest redirects" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.createDirPath(testing.io, ".well-known/acme-challenge") catch @panic("fixture dir failed");
    writeFixture(tmp.dir, ".well-known/acme-challenge/tok_a", "tok_a.print");

    var root_buf: [128]u8 = undefined;
    const webroot = fixtureRoot(&root_buf, &tmp);

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 39893);
    const server = try addr.listen(io, .{ .kernel_backlog = 8, .reuse_address = true });

    const state = try State.create(std.testing.allocator, io, server, webroot, null, "127.0.0.1", 39893, 39894);

    var reply_buf: [1024]u8 = undefined;
    const challenge_len = try fetch(io, 39893, "GET /.well-known/acme-challenge/tok_a HTTP/1.1\r\nHost: site.test\r\nConnection: close\r\n\r\n", &reply_buf);
    const challenge = reply_buf[0..challenge_len];
    try testing.expect(std.mem.startsWith(u8, challenge, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.endsWith(u8, challenge, "tok_a.print"));

    const redirect_len = try fetch(io, 39893, "GET /app/page HTTP/1.1\r\nHost: site.test:39893\r\nConnection: close\r\n\r\n", &reply_buf);
    const redirect = reply_buf[0..redirect_len];
    try testing.expect(std.mem.startsWith(u8, redirect, "HTTP/1.1 301 Moved Permanently\r\n"));
    try testing.expect(std.mem.indexOf(u8, redirect, "Location: https://site.test:39894/app/page\r\n") != null);

    state.shutdown();

    // The port is free again: a fresh bind succeeds.
    var rebound = try addr.listen(io, .{ .kernel_backlog = 8, .reuse_address = true });
    rebound.deinit(io);
}
