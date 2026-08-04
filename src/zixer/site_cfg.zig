//! zixer site cfg schema: parse, validate, engine rules

const std = @import("std");

const cfg_scanner = @import("cfg_scanner.zig");
const fault = @import("fault.zig");

pub const Engine = enum {
    HTTP1,
    HTTP2,
    GRPC,
    HTTP3,
    UDP,
};

/// One upstream backend address.
pub const Upstream = struct {
    host: []const u8,
    port: u16,
};

/// Parsed site config. engine and port stay null when the file misses or
/// breaks them, the faults list explains what to fix.
pub const SiteCfg = struct {
    engine: ?Engine = null,
    ip: []const u8 = "0.0.0.0",
    port: ?u16 = null,
    tls: bool = false,
    tls_cert: ?[]const u8 = null,
    tls_key: ?[]const u8 = null,
    acme_webroot: ?[]const u8 = null,
    acme_proxy: ?Upstream = null,
    upstreams: []const Upstream = &.{},
    public_dir: ?[]const u8 = null,
    public_prefix: ?[]const u8 = null,
    spa_fallback: ?[]const u8 = null,
    kernel_backlog: ?u31 = null,
    max_recv_buf: ?usize = null,
};

/// Known site cfg keys. Field names mirror the cfg key strings exactly so
/// stringToEnum does the lookup, hence lower_case here.
const Key = enum {
    engine,
    ip,
    port,
    tls,
    tls_cert,
    tls_key,
    acme_webroot,
    acme_proxy,
    upstreams,
    public_dir,
    public_prefix,
    spa_fallback,
    kernel_backlog,
    max_recv_buf,
};

/// Parse and validate one site cfg content.
///
/// Note:
/// - Faults never abort the parse: every problem lands in faults with a fix
///   hint, and the returned config keeps whatever fields did parse.
/// - String values are slices into content, so content must outlive the result.
///
/// Param:
/// arena - std.mem.Allocator (owns the upstreams slice)
/// content - []const u8 (site cfg bytes)
/// faults - *fault.FaultList (collects every validation problem)
///
/// Return:
/// - SiteCfg, valid when faults stays empty
pub fn parse(arena: std.mem.Allocator, content: []const u8, faults: *fault.FaultList) !SiteCfg {
    var cfg = SiteCfg{};
    var seen: std.EnumSet(Key) = .empty;

    var scanner = cfg_scanner.Scanner.init(content);
    while (scanner.next()) |line| {
        const entry = switch (line) {
            .bad => |bad| {
                try fault.addBadLine(faults, bad);
                continue;
            },
            .entry => |entry| entry,
        };

        const key = std.meta.stringToEnum(Key, entry.key) orelse {
            try faults.add(entry.key, "unknown key, remove it or fix the typo", .{});
            continue;
        };

        if (seen.contains(key)) {
            try faults.add(entry.key, "duplicate key, keep one line", .{});
            continue;
        }
        seen.insert(key);

        switch (key) {
            .engine => {
                cfg.engine = parseEngine(entry.value) orelse {
                    try faults.add(entry.key, "unknown value '{s}', use http1, http2, grpc, http3, or udp", .{entry.value});
                    continue;
                };
            },
            .ip => {
                _ = std.Io.net.IpAddress.parse(entry.value, 0) catch {
                    try faults.add(entry.key, "'{s}' is not an ip address, i.e. 0.0.0.0 or ::", .{entry.value});
                    continue;
                };

                cfg.ip = entry.value;
            },
            .port => {
                const value = try fault.evalNumber(faults, entry) orelse continue;
                const port = std.math.cast(u16, value) orelse {
                    try faults.add(entry.key, "must be 1-65535", .{});
                    continue;
                };

                if (port == 0) {
                    try faults.add(entry.key, "must be 1-65535", .{});
                    continue;
                }

                cfg.port = port;
            },
            .tls => {
                cfg.tls = cfg_scanner.parseBool(entry.value) orelse {
                    try faults.add(entry.key, "'{s}' is not a boolean, use true or false", .{entry.value});
                    continue;
                };
            },
            .tls_cert => cfg.tls_cert = entry.value,
            .tls_key => cfg.tls_key = entry.value,
            .acme_webroot => cfg.acme_webroot = entry.value,
            .acme_proxy => {
                cfg.acme_proxy = parseHostPort(entry.value) orelse {
                    try faults.add(entry.key, "'{s}' is not host:port, i.e. 127.0.0.1:9080", .{entry.value});
                    continue;
                };
            },
            .upstreams => cfg.upstreams = try parseUpstreams(arena, entry, faults),
            .public_dir => cfg.public_dir = entry.value,
            .public_prefix => {
                if (entry.value[0] != '/') {
                    try faults.add(entry.key, "must start with /, i.e. /assets", .{});
                    continue;
                }

                cfg.public_prefix = entry.value;
            },
            .spa_fallback => cfg.spa_fallback = entry.value,
            .kernel_backlog => {
                const value = try fault.evalNumber(faults, entry) orelse continue;
                const backlog = std.math.cast(u31, value) orelse {
                    try faults.add(entry.key, "must be 1-{d}", .{std.math.maxInt(u31)});
                    continue;
                };

                if (backlog == 0) {
                    try faults.add(entry.key, "must be at least 1", .{});
                    continue;
                }

                cfg.kernel_backlog = backlog;
            },
            .max_recv_buf => {
                const value = try fault.evalNumber(faults, entry) orelse continue;
                if (value < 1) {
                    try faults.add(entry.key, "must be at least 1", .{});
                    continue;
                }

                cfg.max_recv_buf = @intCast(value);
            },
        }
    }

    try validate(&cfg, seen, faults);

    return cfg;
}

/// Cross-field rules, run after the scan so every field is in place.
fn validate(cfg: *const SiteCfg, seen: std.EnumSet(Key), faults: *fault.FaultList) !void {
    if (!seen.contains(.engine)) try faults.add("engine", "missing, set one of http1, http2, grpc, http3, udp", .{});
    if (!seen.contains(.port)) try faults.add("port", "missing, set 1-65535", .{});

    if (cfg.tls) {
        if (cfg.tls_cert == null) try faults.add("tls_cert", "required when tls: true", .{});
        if (cfg.tls_key == null) try faults.add("tls_key", "required when tls: true", .{});
    } else {
        if (cfg.tls_cert != null) try faults.add("tls_cert", "set tls: true or remove it", .{});
        if (cfg.tls_key != null) try faults.add("tls_key", "set tls: true or remove it", .{});
    }

    if (cfg.upstreams.len == 0 and cfg.public_dir == null) {
        try faults.add("upstreams", "site needs upstreams or public_dir", .{});
    }

    if (cfg.public_prefix != null and cfg.public_dir == null) {
        try faults.add("public_prefix", "needs public_dir", .{});
    }
    if (cfg.spa_fallback != null and cfg.public_dir == null) {
        try faults.add("spa_fallback", "needs public_dir", .{});
    }

    // Without a prefix bound, every backend miss on a proxied site would
    // swallow into the fallback page instead of reaching the upstream.
    if (cfg.spa_fallback != null and cfg.upstreams.len > 0 and cfg.public_prefix == null) {
        try faults.add("spa_fallback", "needs public_prefix when upstreams are set", .{});
    }

    if (cfg.acme_webroot != null and cfg.acme_proxy != null) {
        try faults.add("acme_proxy", "choose acme_webroot or acme_proxy, not both", .{});
    }

    const engine = cfg.engine orelse return;

    switch (engine) {
        .HTTP1, .HTTP2 => {},
        .HTTP3 => {
            if (!cfg.tls) try faults.add("tls", "http3 requires tls: true", .{});
        },
        .GRPC => {
            if (cfg.public_dir != null) try faults.add("public_dir", "not supported on grpc sites, remove it", .{});
        },
        .UDP => {
            if (cfg.tls) try faults.add("tls", "udp forward is blind bytes, tls does not apply", .{});
            if (cfg.public_dir != null) try faults.add("public_dir", "not supported on udp sites, remove it", .{});
            if (cfg.kernel_backlog != null) try faults.add("kernel_backlog", "does not apply to udp sites, remove it", .{});
            if (cfg.acme_webroot != null) try faults.add("acme_webroot", "does not apply to udp sites, remove it", .{});
            if (cfg.acme_proxy != null) try faults.add("acme_proxy", "does not apply to udp sites, remove it", .{});
        },
    }
}

/// Parse the comma-separated upstreams value into owned entries.
fn parseUpstreams(arena: std.mem.Allocator, entry: cfg_scanner.Entry, faults: *fault.FaultList) ![]const Upstream {
    var list: std.ArrayList(Upstream) = .empty;

    var iter = cfg_scanner.ListIterator.init(entry.value);
    while (iter.next()) |item| {
        if (item.len == 0) {
            try faults.add(entry.key, "empty entry in the list, remove the extra comma", .{});
            continue;
        }

        const upstream = parseHostPort(item) orelse {
            try faults.add(entry.key, "'{s}' is not host:port, i.e. 127.0.0.1:3000", .{item});
            continue;
        };

        try list.append(arena, upstream);
    }

    return list.items;
}

/// Split "host:port" on the last ':'. Null when either side is unusable.
fn parseHostPort(value: []const u8) ?Upstream {
    const colon_pos = std.mem.lastIndexOfScalar(u8, value, ':') orelse return null;

    const host = value[0..colon_pos];
    if (host.len == 0) return null;

    const port = std.fmt.parseInt(u16, value[colon_pos + 1 ..], 10) catch return null;
    if (port == 0) return null;

    return .{ .host = host, .port = port };
}

/// Cfg spelling to engine value, null when unknown.
fn parseEngine(value: []const u8) ?Engine {
    if (std.mem.eql(u8, value, "http1")) return .HTTP1;
    if (std.mem.eql(u8, value, "http2")) return .HTTP2;
    if (std.mem.eql(u8, value, "grpc")) return .GRPC;
    if (std.mem.eql(u8, value, "http3")) return .HTTP3;
    if (std.mem.eql(u8, value, "udp")) return .UDP;

    return null;
}

/// Lowercase cfg spelling of an engine value, for status output.
pub fn engineName(engine: Engine) []const u8 {
    return switch (engine) {
        .HTTP1 => "http1",
        .HTTP2 => "http2",
        .GRPC => "grpc",
        .HTTP3 => "http3",
        .UDP => "udp",
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

const testing = std.testing;

test "zix zixer: site cfg, full proxied site parses clean" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const content =
        "engine: http1\n" ++
        "ip: 0.0.0.0\n" ++
        "port: 443\n" ++
        "\n" ++
        "tls: true\n" ++
        "tls_cert: /etc/letsencrypt/live/example.com/fullchain.pem\n" ++
        "tls_key: /etc/letsencrypt/live/example.com/privkey.pem\n" ++
        "acme_webroot: /var/www/acme\n" ++
        "\n" ++
        "upstreams: 127.0.0.1:3000, 127.0.0.1:3001\n" ++
        "public_dir: /var/www/app/dist\n" ++
        "public_prefix: /assets\n" ++
        "max_recv_buf: 16 * 1024\n";

    var faults = fault.FaultList.init(arena.allocator());
    const cfg = try parse(arena.allocator(), content, &faults);

    try testing.expectEqual(@as(usize, 0), faults.slice().len);
    try testing.expectEqual(Engine.HTTP1, cfg.engine.?);
    try testing.expectEqual(@as(u16, 443), cfg.port.?);
    try testing.expect(cfg.tls);
    try testing.expectEqual(@as(usize, 2), cfg.upstreams.len);
    try testing.expectEqualStrings("127.0.0.1", cfg.upstreams[1].host);
    try testing.expectEqual(@as(u16, 3001), cfg.upstreams[1].port);
    try testing.expectEqualStrings("/assets", cfg.public_prefix.?);
    try testing.expectEqual(@as(usize, 16384), cfg.max_recv_buf.?);
}

test "zix zixer: site cfg, static-only http3 site parses clean" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const content =
        "engine: http3\n" ++
        "ip: 0.0.0.0\n" ++
        "port: 8443\n" ++
        "tls: true\n" ++
        "tls_cert: /certs/fullchain.pem\n" ++
        "tls_key: /certs/privkey.pem\n" ++
        "public_dir: /var/www/pages/dist\n" ++
        "spa_fallback: index.html\n";

    var faults = fault.FaultList.init(arena.allocator());
    const cfg = try parse(arena.allocator(), content, &faults);

    try testing.expectEqual(@as(usize, 0), faults.slice().len);
    try testing.expectEqual(Engine.HTTP3, cfg.engine.?);
    try testing.expectEqual(@as(usize, 0), cfg.upstreams.len);
    try testing.expectEqualStrings("index.html", cfg.spa_fallback.?);
}

test "zix zixer: site cfg, missing engine and port fault" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var faults = fault.FaultList.init(arena.allocator());
    const cfg = try parse(arena.allocator(), "upstreams: 127.0.0.1:3000\n", &faults);

    try testing.expectEqual(@as(?Engine, null), cfg.engine);
    try testing.expectEqual(@as(usize, 2), faults.slice().len);
    try testing.expectEqualStrings("engine", faults.slice()[0].key);
    try testing.expectEqualStrings("port", faults.slice()[1].key);
}

test "zix zixer: site cfg, tls cross-checks both directions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var on_faults = fault.FaultList.init(arena.allocator());
    _ = try parse(arena.allocator(), "engine: http1\nport: 443\ntls: true\nupstreams: 127.0.0.1:3000\n", &on_faults);
    try testing.expectEqual(@as(usize, 2), on_faults.slice().len);
    try testing.expectEqualStrings("tls_cert", on_faults.slice()[0].key);
    try testing.expectEqualStrings("tls_key", on_faults.slice()[1].key);

    var off_faults = fault.FaultList.init(arena.allocator());
    _ = try parse(arena.allocator(), "engine: http1\nport: 80\ntls_cert: /x.pem\nupstreams: 127.0.0.1:3000\n", &off_faults);
    try testing.expectEqual(@as(usize, 1), off_faults.slice().len);
    try testing.expectEqualStrings("tls_cert", off_faults.slice()[0].key);
    try testing.expectEqualStrings("set tls: true or remove it", off_faults.slice()[0].hint);
}

test "zix zixer: site cfg, http3 without tls faults" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var faults = fault.FaultList.init(arena.allocator());
    _ = try parse(arena.allocator(), "engine: http3\nport: 8443\npublic_dir: /var/www\n", &faults);

    try testing.expectEqual(@as(usize, 1), faults.slice().len);
    try testing.expectEqualStrings("tls", faults.slice()[0].key);
    try testing.expectEqualStrings("http3 requires tls: true", faults.slice()[0].hint);
}

test "zix zixer: site cfg, udp rejects tls public_dir kernel_backlog acme" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const content =
        "engine: udp\n" ++
        "port: 50000\n" ++
        "tls: true\n" ++
        "tls_cert: /x.pem\n" ++
        "tls_key: /x.key\n" ++
        "public_dir: /var/www\n" ++
        "kernel_backlog: 1024\n" ++
        "acme_webroot: /var/www/acme\n" ++
        "upstreams: 127.0.0.1:50001\n";

    var faults = fault.FaultList.init(arena.allocator());
    _ = try parse(arena.allocator(), content, &faults);

    var tls_faulted = false;
    var public_dir_faulted = false;
    var backlog_faulted = false;
    var acme_faulted = false;
    for (faults.slice()) |item| {
        if (std.mem.eql(u8, item.key, "tls")) tls_faulted = true;
        if (std.mem.eql(u8, item.key, "public_dir")) public_dir_faulted = true;
        if (std.mem.eql(u8, item.key, "kernel_backlog")) backlog_faulted = true;
        if (std.mem.eql(u8, item.key, "acme_webroot")) acme_faulted = true;
    }

    try testing.expect(tls_faulted);
    try testing.expect(public_dir_faulted);
    try testing.expect(backlog_faulted);
    try testing.expect(acme_faulted);
}

test "zix zixer: site cfg, grpc rejects public_dir" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var faults = fault.FaultList.init(arena.allocator());
    _ = try parse(arena.allocator(), "engine: grpc\nport: 50051\npublic_dir: /var/www\nupstreams: 127.0.0.1:9000\n", &faults);

    try testing.expectEqual(@as(usize, 1), faults.slice().len);
    try testing.expectEqualStrings("public_dir", faults.slice()[0].key);
    try testing.expectEqualStrings("not supported on grpc sites, remove it", faults.slice()[0].hint);
}

test "zix zixer: site cfg, neither upstreams nor public_dir faults" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var faults = fault.FaultList.init(arena.allocator());
    _ = try parse(arena.allocator(), "engine: http1\nport: 8080\n", &faults);

    try testing.expectEqual(@as(usize, 1), faults.slice().len);
    try testing.expectEqualStrings("upstreams", faults.slice()[0].key);
    try testing.expectEqualStrings("site needs upstreams or public_dir", faults.slice()[0].hint);
}

test "zix zixer: site cfg, prefix and spa fallback need public_dir" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const content =
        "engine: http1\n" ++
        "port: 8080\n" ++
        "upstreams: 127.0.0.1:3000\n" ++
        "public_prefix: /assets\n" ++
        "spa_fallback: index.html\n";

    var faults = fault.FaultList.init(arena.allocator());
    _ = try parse(arena.allocator(), content, &faults);

    try testing.expectEqual(@as(usize, 2), faults.slice().len);
    try testing.expectEqualStrings("public_prefix", faults.slice()[0].key);
    try testing.expectEqualStrings("spa_fallback", faults.slice()[1].key);
}

test "zix zixer: site cfg, spa fallback beside upstreams needs a prefix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const bare =
        "engine: http1\n" ++
        "port: 8080\n" ++
        "upstreams: 127.0.0.1:3000\n" ++
        "public_dir: /www\n" ++
        "spa_fallback: index.html\n";

    var faults = fault.FaultList.init(arena.allocator());
    _ = try parse(arena.allocator(), bare, &faults);

    try testing.expectEqual(@as(usize, 1), faults.slice().len);
    try testing.expectEqualStrings("spa_fallback", faults.slice()[0].key);
    try testing.expectEqualStrings("needs public_prefix when upstreams are set", faults.slice()[0].hint);

    // With the prefix bound, the same site is clean.
    const bounded =
        "engine: http1\n" ++
        "port: 8080\n" ++
        "upstreams: 127.0.0.1:3000\n" ++
        "public_dir: /www\n" ++
        "public_prefix: /app\n" ++
        "spa_fallback: index.html\n";

    var bounded_faults = fault.FaultList.init(arena.allocator());
    _ = try parse(arena.allocator(), bounded, &bounded_faults);

    try testing.expectEqual(@as(usize, 0), bounded_faults.slice().len);
}

test "zix zixer: site cfg, prefix without leading slash faults" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var faults = fault.FaultList.init(arena.allocator());
    const cfg = try parse(arena.allocator(), "engine: http1\nport: 8080\npublic_dir: /www\npublic_prefix: assets\n", &faults);

    try testing.expectEqual(@as(?[]const u8, null), cfg.public_prefix);
    try testing.expectEqual(@as(usize, 1), faults.slice().len);
    try testing.expectEqualStrings("must start with /, i.e. /assets", faults.slice()[0].hint);
}

test "zix zixer: site cfg, bad upstream entries fault one by one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var faults = fault.FaultList.init(arena.allocator());
    const cfg = try parse(arena.allocator(), "engine: http1\nport: 8080\nupstreams: 127.0.0.1:3000,, localhost, 127.0.0.1:0\n", &faults);

    try testing.expectEqual(@as(usize, 1), cfg.upstreams.len);
    try testing.expectEqual(@as(usize, 3), faults.slice().len);
    try testing.expectEqualStrings("empty entry in the list, remove the extra comma", faults.slice()[0].hint);
    try testing.expectEqualStrings("'localhost' is not host:port, i.e. 127.0.0.1:3000", faults.slice()[1].hint);
    try testing.expectEqualStrings("'127.0.0.1:0' is not host:port, i.e. 127.0.0.1:3000", faults.slice()[2].hint);
}

test "zix zixer: site cfg, both acme modes together fault" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const content =
        "engine: http1\n" ++
        "port: 443\n" ++
        "tls: true\n" ++
        "tls_cert: /x.pem\n" ++
        "tls_key: /x.key\n" ++
        "acme_webroot: /var/www/acme\n" ++
        "acme_proxy: 127.0.0.1:9080\n" ++
        "upstreams: 127.0.0.1:3000\n";

    var faults = fault.FaultList.init(arena.allocator());
    _ = try parse(arena.allocator(), content, &faults);

    try testing.expectEqual(@as(usize, 1), faults.slice().len);
    try testing.expectEqualStrings("acme_proxy", faults.slice()[0].key);
    try testing.expectEqualStrings("choose acme_webroot or acme_proxy, not both", faults.slice()[0].hint);
}

test "zix zixer: site cfg, bad ip and bad port fault" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var faults = fault.FaultList.init(arena.allocator());
    const cfg = try parse(arena.allocator(), "engine: http1\nip: not-an-ip\nport: 70000\nupstreams: 127.0.0.1:3000\n", &faults);

    try testing.expectEqual(@as(?u16, null), cfg.port);
    try testing.expectEqualStrings("0.0.0.0", cfg.ip);
    try testing.expectEqual(@as(usize, 2), faults.slice().len);
    try testing.expectEqualStrings("ip", faults.slice()[0].key);
    try testing.expectEqualStrings("must be 1-65535", faults.slice()[1].hint);
}

test "zix zixer: site cfg, engine names round trip" {
    try testing.expectEqual(Engine.HTTP1, parseEngine("http1").?);
    try testing.expectEqual(Engine.UDP, parseEngine("udp").?);
    try testing.expectEqual(@as(?Engine, null), parseEngine("h2"));

    try testing.expectEqualStrings("http1", engineName(.HTTP1));
    try testing.expectEqualStrings("http2", engineName(.HTTP2));
    try testing.expectEqualStrings("grpc", engineName(.GRPC));
    try testing.expectEqualStrings("http3", engineName(.HTTP3));
    try testing.expectEqualStrings("udp", engineName(.UDP));
}
