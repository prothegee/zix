//! rediz edge suite: refusals, bounds and broken connections against the
//! in-process server.
//!
//! Note:
//! - No container and no daemon, so this runs on every supported platform.
//!   It is the docker-free twin of the failure-path half of
//!   tests/integration.zig, which stays as the live coverage for maintainers.
//! - Each test starts its own server on a kernel-assigned port, so a test that
//!   deliberately breaks a connection cannot disturb another.

const std = @import("std");
const rediz = @import("rediz");

const inproc = @import("inproc/server.zig");

const testing = std.testing;

/// Credentials the ACL-guarded tests share.
const ACL_USER = "role_acl";
const ACL_PASSWORD = "rediz_acl_pw";

const ACL_OPTIONS = inproc.Options{ .user = ACL_USER, .password = ACL_PASSWORD };

const Harness = struct {
    threaded: std.Io.Threaded,
    arena: std.heap.ArenaAllocator,
    server: *inproc.Server,

    fn start(self: *Harness, options: inproc.Options) !void {
        self.threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        errdefer self.threaded.deinit();

        self.arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        errdefer self.arena.deinit();

        self.server = try inproc.Server.start(std.heap.smp_allocator, self.threaded.io(), options);
    }

    fn open(self: *Harness) !void {
        return self.start(.{});
    }

    fn stop(self: *Harness) void {
        self.server.stop();
        self.arena.deinit();
        self.threaded.deinit();
    }

    fn io(self: *Harness) std.Io {
        return self.threaded.io();
    }

    fn allocator(self: *Harness) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn config(self: *Harness) rediz.Config {
        return .{ .ip = inproc.IP, .port = self.server.port };
    }

    fn connect(self: *Harness) !*rediz.Conn {
        return rediz.Conn.connect(self.allocator(), self.io(), self.config());
    }
};

test "rediz edge: a wrong password surfaces WRONGPASS" {
    var harness: Harness = undefined;
    try harness.start(ACL_OPTIONS);
    defer harness.stop();

    var config = harness.config();
    config.user = ACL_USER;
    config.password = "wrong";

    try testing.expectError(error.ServerError, rediz.Conn.connect(harness.allocator(), harness.io(), config));
}

test "rediz edge: connecting with no credentials to a guarded server is refused" {
    var harness: Harness = undefined;
    try harness.start(ACL_OPTIONS);
    defer harness.stop();

    // no password in the config, so HELLO carries no AUTH clause and the
    // server answers NOAUTH before anything else can run
    try testing.expectError(error.ServerError, harness.connect());
}

test "rediz edge: a strict resp3 config fails against a server without hello" {
    var harness: Harness = undefined;
    try harness.start(.{ .resp3_supported = false });
    defer harness.stop();

    var config = harness.config();
    config.protocol_version = .RESP3;

    try testing.expectError(error.ProtocolNotSupported, rediz.Conn.connect(harness.allocator(), harness.io(), config));
}

test "rediz edge: connecting to a closed port is refused" {
    var harness: Harness = undefined;
    try harness.open();
    defer harness.stop();

    // take the port away before anyone dials it
    const dead_port = harness.server.port;
    harness.server.stop();

    var config = harness.config();
    config.port = dead_port;

    const result = rediz.Conn.connect(harness.allocator(), harness.io(), config);
    try testing.expectError(error.ConnectionRefused, result);

    // the harness must not stop a server that is already gone
    harness.server = try inproc.Server.start(std.heap.smp_allocator, harness.io(), .{});
}

test "rediz edge: wrongtype surfaces the mapped prefix" {
    var harness: Harness = undefined;
    try harness.open();
    defer harness.stop();

    const conn = try harness.connect();
    defer conn.deinit();

    _ = try conn.command(&.{ "RPUSH", "wrong:list", "item" });

    try testing.expectError(error.ServerError, conn.incr("wrong:list"));
    try testing.expectEqual(rediz.Prefix.WRONGTYPE, conn.lastServerError().prefix);
}

test "rediz edge: incrementing a non-numeric value surfaces the ERR prefix" {
    var harness: Harness = undefined;
    try harness.open();
    defer harness.stop();

    const conn = try harness.connect();
    defer conn.deinit();

    _ = try conn.set("word", "abc", .{});

    try testing.expectError(error.ServerError, conn.incr("word"));
    try testing.expectEqual(rediz.Prefix.ERR, conn.lastServerError().prefix);
}

test "rediz edge: an unparseable json value surfaces BadJson, the text stays readable" {
    var harness: Harness = undefined;
    try harness.open();
    defer harness.stop();

    const conn = try harness.connect();
    defer conn.deinit();

    const Item = struct {
        id: i64,
        name: []const u8,
    };

    _ = try conn.set("json:broken", "not-json", .{});

    try testing.expectError(error.BadJson, conn.getJson(Item, "json:broken"));
    try testing.expectEqualStrings("not-json", (try conn.get("json:broken")).?);
}

test "rediz edge: max_pending_replies bounds a pipeline batch" {
    var harness: Harness = undefined;
    try harness.open();
    defer harness.stop();

    var config = harness.config();
    config.max_pending_replies = 2;

    const conn = try rediz.Conn.connect(harness.allocator(), harness.io(), config);
    defer conn.deinit();

    var pipe = try conn.pipeline();
    try pipe.add(&.{ "SET", "bound:a", "1" });
    try pipe.add(&.{ "SET", "bound:b", "2" });
    try testing.expectError(error.QueueFull, pipe.add(&.{ "SET", "bound:c", "3" }));

    const replies = try pipe.sync();
    try testing.expectEqual(@as(usize, 2), replies.len);
    try testing.expect(replies[0].isOk());
    try testing.expect(replies[1].isOk());
}

test "rediz edge: a deferred flood stays at the queue bound" {
    var harness: Harness = undefined;
    try harness.open();
    defer harness.stop();

    var config = harness.config();
    config.max_pending_replies = 8;

    const conn = try rediz.Conn.connect(harness.allocator(), harness.io(), config);
    defer conn.deinit();

    var key_buf: [32]u8 = undefined;
    for (0..100) |index| {
        const key = try std.fmt.bufPrint(&key_buf, "deferred:flood:{d}", .{index});
        try conn.setDeferred(key, "x", .{ .ex_s = 5 });
        try testing.expect(conn.pendingDeferred() <= 8);
    }

    try conn.drainDeferred();
    try testing.expectEqual(@as(usize, 0), conn.pendingDeferred());
    try testing.expectEqual(@as(u64, 0), conn.deferredErrorCount());
    try testing.expectEqualStrings("x", (try conn.get("deferred:flood:99")).?);
}

test "rediz edge: a refused deferred write is counted, not thrown" {
    var harness: Harness = undefined;
    try harness.start(.{ .fail_command = "SET" });
    defer harness.stop();

    const conn = try harness.connect();
    defer conn.deinit();

    // the write-behind path never throws, so a server that has stopped
    // accepting writes has to show up in the counter instead
    try conn.setDeferred("deferred:key", "value", .{});
    try conn.drainDeferred();

    try testing.expectEqual(@as(usize, 0), conn.pendingDeferred());
    try testing.expectEqual(@as(u64, 1), conn.deferredErrorCount());
    try testing.expectEqual(rediz.Prefix.MISCONF, conn.lastServerError().prefix);
}

test "rediz edge: a pool heals a killed connection" {
    var harness: Harness = undefined;
    try harness.open();
    defer harness.stop();

    var config = harness.config();
    config.pool_size = 1;
    config.retry_max = 2;
    config.retry_delay_ms = 50;

    var pool = try rediz.Pool.init(harness.allocator(), harness.io(), config);
    defer pool.deinit();

    // learn the pooled connection's id, then give it back
    const pooled = try pool.acquire();
    const id_reply = try pooled.command(&.{ "CLIENT", "ID" });
    const pooled_id = id_reply.integer;
    pool.release(pooled);

    // kill it from a separate connection
    const killer = try harness.connect();
    defer killer.deinit();
    var id_buf: [20]u8 = undefined;
    const id_text = try std.fmt.bufPrint(&id_buf, "{d}", .{pooled_id});
    _ = try killer.command(&.{ "CLIENT", "KILL", "ID", id_text });

    // the idle slot hands back the dead connection: discard + reacquire heals
    const dead = try pool.acquire();
    try testing.expectError(error.ConnectionClosed, dead.ping());
    pool.discard(dead);

    const healed = try pool.acquire();
    defer pool.release(healed);
    try healed.ping();
}

test "rediz edge: a fully-held pool without parking sheds immediately" {
    var harness: Harness = undefined;
    try harness.open();
    defer harness.stop();

    var config = harness.config();
    config.pool_size = 1;
    config.process_queue_len = 0;

    var pool = try rediz.Pool.init(harness.allocator(), harness.io(), config);
    defer pool.deinit();

    const held = try pool.acquire();
    defer pool.release(held);

    try testing.expectError(error.PoolExhausted, pool.acquire());
}

test "rediz edge: select rejects an index outside the database range" {
    var harness: Harness = undefined;
    try harness.open();
    defer harness.stop();

    const conn = try harness.connect();
    defer conn.deinit();

    try testing.expectError(error.ServerError, conn.select(99));
    try testing.expectEqual(rediz.Prefix.ERR, conn.lastServerError().prefix);

    // the connection is still usable after a rejected command
    try conn.ping();
}

test "rediz edge: an unknown command is an error reply, not a dead connection" {
    var harness: Harness = undefined;
    try harness.open();
    defer harness.stop();

    const conn = try harness.connect();
    defer conn.deinit();

    try testing.expectError(error.ServerError, conn.command(&.{ "NOSUCHCOMMAND", "x" }));
    try testing.expectEqual(rediz.Prefix.ERR, conn.lastServerError().prefix);

    try conn.ping();
}

test "rediz edge: a command on a killed connection reports it closed" {
    var harness: Harness = undefined;
    try harness.open();
    defer harness.stop();

    const victim = try harness.connect();
    defer victim.deinit();

    const id_reply = try victim.command(&.{ "CLIENT", "ID" });

    const killer = try harness.connect();
    defer killer.deinit();
    var id_buf: [20]u8 = undefined;
    const id_text = try std.fmt.bufPrint(&id_buf, "{d}", .{id_reply.integer});
    _ = try killer.command(&.{ "CLIENT", "KILL", "ID", id_text });

    try testing.expectError(error.ConnectionClosed, victim.ping());
}

test "rediz edge: an empty value round trips without being mistaken for a miss" {
    var harness: Harness = undefined;
    try harness.open();
    defer harness.stop();

    const conn = try harness.connect();
    defer conn.deinit();

    try testing.expectEqual(true, try conn.set("empty:key", "", .{}));

    const value = try conn.get("empty:key");
    try testing.expect(value != null);
    try testing.expectEqualStrings("", value.?);
    try testing.expectEqual(@as(u64, 0), try conn.strlen("empty:key"));
}

test "rediz edge: strlen and ttl on a missing key answer their sentinels" {
    var harness: Harness = undefined;
    try harness.open();
    defer harness.stop();

    const conn = try harness.connect();
    defer conn.deinit();

    try testing.expectEqual(@as(u64, 0), try conn.strlen("absent"));
    try testing.expectEqual(@as(i64, -2), try conn.ttl("absent"));
    try testing.expectEqual(@as(i64, -2), try conn.pttl("absent"));
    try testing.expectEqual(false, try conn.persist("absent"));
    try testing.expectEqual(false, try conn.expire("absent", 30));
    try testing.expectEqualStrings("none", try conn.keyType("absent"));
    try testing.expectEqual(@as(u64, 0), try conn.del(&.{"absent"}));
}

test "rediz edge: a tls value larger than one record round trips" {
    var harness: Harness = undefined;
    try harness.start(.{ .tls = true });
    defer harness.stop();

    var config = harness.config();
    config.tls = .REQUIRE;

    const conn = try rediz.Conn.connect(harness.allocator(), harness.io(), config);
    defer conn.deinit();

    // a TLS record caps at 16 KiB of plaintext, so this has to be split and
    // reassembled on both sides
    const big = try harness.allocator().alloc(u8, 40 * 1024);
    for (big, 0..) |*byte, index| byte.* = @intCast('a' + index % 26);

    try testing.expectEqual(true, try conn.set("tls:big", big, .{}));

    const loaded = (try conn.get("tls:big")).?;
    try testing.expectEqual(big.len, loaded.len);
    try testing.expectEqualSlices(u8, big, loaded);
}

test "rediz edge: a cleartext client against a tls server does not connect" {
    var harness: Harness = undefined;
    try harness.start(.{ .tls = true });
    defer harness.stop();

    // the config leaves tls off, so the driver sends RESP where the server
    // expects a ClientHello and the connection dies rather than hanging
    try testing.expectError(error.ConnectionClosed, harness.connect());
}

test "rediz edge: a tls client against a cleartext server does not connect" {
    var harness: Harness = undefined;
    try harness.open();
    defer harness.stop();

    var config = harness.config();
    config.tls = .REQUIRE;

    try testing.expectError(error.ConnectionClosed, rediz.Conn.connect(harness.allocator(), harness.io(), config));
}

test "rediz edge: an expired key reads back as a miss" {
    var harness: Harness = undefined;
    try harness.open();
    defer harness.stop();

    const conn = try harness.connect();
    defer conn.deinit();

    try testing.expectEqual(true, try conn.set("brief", "value", .{ .px_ms = 1 }));

    harness.io().sleep(.fromMilliseconds(25), .awake) catch {};

    try testing.expectEqual(@as(?[]const u8, null), try conn.get("brief"));
    try testing.expectEqual(@as(i64, -2), try conn.ttl("brief"));
}
