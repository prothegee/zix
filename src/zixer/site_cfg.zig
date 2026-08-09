//! zixer site cfg schema: parse, validate, engine rules

const std = @import("std");

const cfg_scanner = @import("cfg_scanner.zig");
const conn_buffer = @import("conn_buffer.zig");
const deadline_table = @import("deadline_table.zig");
const fault = @import("fault.zig");
const process_gate = @import("process_gate.zig");
const static_cached = @import("static_cached.zig");
const upstream_conn = @import("upstream_conn.zig");

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
    /// How long one client exchange may take before the edge cuts it. Null
    /// takes the main.cfg value, 0 turns the bound off.
    client_timeout_ms: ?u32 = null,
    /// Client connections this site tracks at once while the bound is on. A
    /// connection arriving with every slot taken is refused with 503. Null
    /// takes the main.cfg value.
    client_conn_limit: ?usize = null,
    /// How long the edge waits on a silent upstream before it answers 504.
    /// Null takes the built-in default, 0 turns the bound off.
    upstream_timeout_ms: ?u32 = null,
    /// How long a connect to an upstream may take before the edge answers
    /// 504. Null takes the main.cfg value, 0 waits on the operating system.
    upstream_connect_timeout_ms: ?u32 = null,
    /// How long an unused upstream connection is kept for the next request.
    /// Null takes the main.cfg value, 0 keeps none at all.
    upstream_idle_ttl_ms: ?u32 = null,
    /// Requests this site may have running upstream at once. Null takes the
    /// main.cfg value, 0 turns the gate off for this site alone.
    process_limit: ?usize = null,
    /// Requests that may wait for a process slot. Null takes the main.cfg
    /// value, 0 refuses the moment the limit is reached.
    process_queue_len: ?usize = null,
    /// How long a waiting request holds on before the edge answers 504.
    /// Null takes the main.cfg value.
    process_queue_timeout_ms: ?u32 = null,
    /// How long a cached public_dir file stays fresh for this site. Null takes
    /// the main.cfg value, 0 serves every static request uncached.
    ///
    /// Note:
    /// - There is no site-level entry count. The cache table is one per process
    ///   and its size is fixed the first time a site needs it, so only main.cfg
    ///   sets public_dir_cache_max_entries.
    public_dir_cache_ttl_ms: ?u32 = null,
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
    client_timeout_ms,
    client_conn_limit,
    upstream_timeout_ms,
    upstream_connect_timeout_ms,
    upstream_idle_ttl_ms,
    process_limit,
    process_queue_len,
    process_queue_timeout_ms,
    public_dir_cache_ttl_ms,
    /// Named here only so a site that sets it gets told where it belongs
    /// instead of the generic unknown-key hint.
    public_dir_cache_max_entries,
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
                const bytes = std.math.cast(usize, value) orelse {
                    try faults.add(entry.key, "must be {d}-{d} bytes", .{ conn_buffer.MIN_BYTES, conn_buffer.MAX_BYTES });
                    continue;
                };

                if (!conn_buffer.inRange(bytes)) {
                    try faults.add(entry.key, "must be {d}-{d} bytes", .{ conn_buffer.MIN_BYTES, conn_buffer.MAX_BYTES });
                    continue;
                }

                cfg.max_recv_buf = bytes;
            },
            .client_timeout_ms => {
                const value = try fault.evalNumber(faults, entry) orelse continue;
                const budget = std.math.cast(u32, value) orelse {
                    try faults.add(entry.key, "must be 0-{d} ms, 0 turns the bound off", .{deadline_table.MAX_TIMEOUT_MS});
                    continue;
                };

                if (!deadline_table.timeoutInRange(budget)) {
                    try faults.add(entry.key, "must be 0-{d} ms, 0 turns the bound off", .{deadline_table.MAX_TIMEOUT_MS});
                    continue;
                }

                cfg.client_timeout_ms = budget;
            },
            .client_conn_limit => {
                const value = try fault.evalNumber(faults, entry) orelse continue;
                const conn_limit = std.math.cast(usize, value) orelse {
                    try faults.add(entry.key, "must be 1-{d}, set client_timeout_ms: 0 to track nothing", .{deadline_table.MAX_SLOTS});
                    continue;
                };

                if (!deadline_table.connLimitInRange(conn_limit)) {
                    try faults.add(entry.key, "must be 1-{d}, set client_timeout_ms: 0 to track nothing", .{deadline_table.MAX_SLOTS});
                    continue;
                }

                cfg.client_conn_limit = conn_limit;
            },
            .upstream_timeout_ms => {
                const value = try fault.evalNumber(faults, entry) orelse continue;
                const budget = std.math.cast(u32, value) orelse {
                    try faults.add(entry.key, "must be 0-{d}, 0 waits forever", .{std.math.maxInt(u32)});
                    continue;
                };

                cfg.upstream_timeout_ms = budget;
            },
            .upstream_connect_timeout_ms => {
                const value = try fault.evalNumber(faults, entry) orelse continue;
                const budget = std.math.cast(u32, value) orelse {
                    try faults.add(entry.key, "must be 0-{d} ms, 0 waits on the operating system", .{upstream_conn.MAX_CONNECT_TIMEOUT_MS});
                    continue;
                };

                if (!upstream_conn.connectTimeoutInRange(budget)) {
                    try faults.add(entry.key, "must be 0-{d} ms, 0 waits on the operating system", .{upstream_conn.MAX_CONNECT_TIMEOUT_MS});
                    continue;
                }

                cfg.upstream_connect_timeout_ms = budget;
            },
            .upstream_idle_ttl_ms => {
                const value = try fault.evalNumber(faults, entry) orelse continue;
                const ttl_ms = std.math.cast(u32, value) orelse {
                    try faults.add(entry.key, "must be 0-{d} ms, 0 keeps no connection", .{upstream_conn.MAX_IDLE_TTL_MS});
                    continue;
                };

                if (!upstream_conn.idleTtlInRange(ttl_ms)) {
                    try faults.add(entry.key, "must be 0-{d} ms, 0 keeps no connection", .{upstream_conn.MAX_IDLE_TTL_MS});
                    continue;
                }

                cfg.upstream_idle_ttl_ms = ttl_ms;
            },
            .process_limit => {
                const value = try fault.evalNumber(faults, entry) orelse continue;
                const limit = std.math.cast(usize, value) orelse {
                    try faults.add(entry.key, "must be 0-{d}, 0 turns the gate off", .{process_gate.MAX_SLOTS});
                    continue;
                };

                if (!process_gate.limitInRange(limit)) {
                    try faults.add(entry.key, "must be 0-{d}, 0 turns the gate off", .{process_gate.MAX_SLOTS});
                    continue;
                }

                cfg.process_limit = limit;
            },
            .process_queue_len => {
                const value = try fault.evalNumber(faults, entry) orelse continue;
                const queue_len = std.math.cast(usize, value) orelse {
                    try faults.add(entry.key, "must be 0-{d}, 0 refuses instead of queueing", .{process_gate.MAX_SLOTS});
                    continue;
                };

                if (!process_gate.queueLenInRange(queue_len)) {
                    try faults.add(entry.key, "must be 0-{d}, 0 refuses instead of queueing", .{process_gate.MAX_SLOTS});
                    continue;
                }

                cfg.process_queue_len = queue_len;
            },
            .process_queue_timeout_ms => {
                const value = try fault.evalNumber(faults, entry) orelse continue;
                const timeout_ms = std.math.cast(u32, value) orelse {
                    try faults.add(entry.key, "must be 1-{d} ms", .{process_gate.MAX_TIMEOUT_MS});
                    continue;
                };

                if (!process_gate.timeoutInRange(timeout_ms)) {
                    try faults.add(entry.key, "must be 1-{d} ms", .{process_gate.MAX_TIMEOUT_MS});
                    continue;
                }

                cfg.process_queue_timeout_ms = timeout_ms;
            },
            .public_dir_cache_ttl_ms => {
                const value = try fault.evalNumber(faults, entry) orelse continue;
                const ttl_ms = std.math.cast(u32, value) orelse {
                    try faults.add(entry.key, "must be 0-{d} ms, 0 turns the cache off", .{static_cached.MAX_TTL_MS});
                    continue;
                };

                if (!static_cached.ttlInRange(ttl_ms)) {
                    try faults.add(entry.key, "must be 0-{d} ms, 0 turns the cache off", .{static_cached.MAX_TTL_MS});
                    continue;
                }

                cfg.public_dir_cache_ttl_ms = ttl_ms;
            },
            .public_dir_cache_max_entries => try faults.add(
                entry.key,
                "set it in main.cfg, the cache table is one per daemon and every site shares it",
                .{},
            ),
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
    if (cfg.public_dir_cache_ttl_ms != null and cfg.public_dir == null) {
        try faults.add("public_dir_cache_ttl_ms", "needs public_dir", .{});
    }

    // Without a prefix bound, every backend miss on a proxied site would
    // swallow into the fallback page instead of reaching the upstream.
    if (cfg.spa_fallback != null and cfg.upstreams.len > 0 and cfg.public_prefix == null) {
        try faults.add("spa_fallback", "needs public_prefix when upstreams are set", .{});
    }

    if (cfg.acme_webroot != null and cfg.acme_proxy != null) {
        try faults.add("acme_proxy", "choose acme_webroot or acme_proxy, not both", .{});
    }

    if (cfg.upstream_timeout_ms != null and cfg.upstreams.len == 0) {
        try faults.add("upstream_timeout_ms", "needs upstreams", .{});
    }

    // Both bound the upstream leg, so a site answering from public_dir alone
    // has no connect to time and no connection to keep.
    if (cfg.upstreams.len == 0) {
        if (cfg.upstream_connect_timeout_ms != null) try faults.add("upstream_connect_timeout_ms", "needs upstreams", .{});
        if (cfg.upstream_idle_ttl_ms != null) try faults.add("upstream_idle_ttl_ms", "needs upstreams", .{});
    }

    // Only checkable when the site names both: a null bound inherits the
    // main.cfg value, which carries its own version of this rule.
    if (cfg.client_timeout_ms != null and cfg.client_timeout_ms.? == 0 and cfg.client_conn_limit != null) {
        try faults.add("client_conn_limit", "needs client_timeout_ms above 0, otherwise nothing is tracked", .{});
    }

    // The gate stands in front of the upstream leg, so a site that answers
    // from public_dir alone has nothing for it to hold back.
    if (cfg.upstreams.len == 0) {
        if (cfg.process_limit != null) try faults.add("process_limit", "needs upstreams", .{});
        if (cfg.process_queue_len != null) try faults.add("process_queue_len", "needs upstreams", .{});
        if (cfg.process_queue_timeout_ms != null) try faults.add("process_queue_timeout_ms", "needs upstreams", .{});
    }

    // Only checkable when the site names both: a null limit inherits the
    // main.cfg value, which carries its own version of this rule.
    if (cfg.process_limit != null and cfg.process_limit.? == 0 and cfg.process_queue_len != null and cfg.process_queue_len.? > 0) {
        try faults.add("process_queue_len", "needs process_limit above 0, otherwise nothing ever queues", .{});
    }

    const engine = cfg.engine orelse return;

    // A cleartext http1 site answers the challenge path on its own
    // listener, a TLS site gets the port 80 companion. On a cleartext
    // non-http1 site the acme keys would never be served (udp keeps its
    // own message below).
    if (!cfg.tls and engine != .HTTP1 and engine != .UDP) {
        if (cfg.acme_webroot != null) try faults.add("acme_webroot", "needs tls: true or an http1 site", .{});
        if (cfg.acme_proxy != null) try faults.add("acme_proxy", "needs tls: true or an http1 site", .{});
    }

    switch (engine) {
        .HTTP1, .HTTP2 => {},
        .HTTP3 => {
            if (!cfg.tls) try faults.add("tls", "http3 requires tls: true", .{});

            // The client bound cuts a socket to reach a connection that ran
            // out of time. A quic connection is not one: the whole site shares
            // a single datagram socket, so these keys would be accepted and
            // never acted on.
            if (cfg.client_timeout_ms != null) try faults.add("client_timeout_ms", "not supported on http3 sites, remove it", .{});
            if (cfg.client_conn_limit != null) try faults.add("client_conn_limit", "not supported on http3 sites, remove it", .{});
        },
        .GRPC => {
            if (cfg.public_dir != null) try faults.add("public_dir", "not supported on grpc sites, remove it", .{});
            if (cfg.public_dir_cache_ttl_ms != null) try faults.add("public_dir_cache_ttl_ms", "not supported on grpc sites, remove it", .{});

            // The grpc upstream leg is one h2 connection multiplexing every
            // stream, so a per-request read bound needs its own mechanism
            // and this key would be accepted and ignored.
            if (cfg.upstream_timeout_ms != null) try faults.add("upstream_timeout_ms", "not supported on grpc sites, remove it", .{});

            // That same connection is held for the life of the exchange
            // rather than parked between requests, so there is no idle cache
            // for an age to bound.
            if (cfg.upstream_idle_ttl_ms != null) try faults.add("upstream_idle_ttl_ms", "not supported on grpc sites, remove it", .{});
        },
        .UDP => {
            if (cfg.tls) try faults.add("tls", "udp forward is blind bytes, tls does not apply", .{});
            if (cfg.public_dir != null) try faults.add("public_dir", "not supported on udp sites, remove it", .{});
            if (cfg.public_dir_cache_ttl_ms != null) try faults.add("public_dir_cache_ttl_ms", "does not apply to udp sites, remove it", .{});
            if (cfg.kernel_backlog != null) try faults.add("kernel_backlog", "does not apply to udp sites, remove it", .{});
            if (cfg.upstream_timeout_ms != null) try faults.add("upstream_timeout_ms", "does not apply to udp sites, remove it", .{});
            if (cfg.upstream_connect_timeout_ms != null) try faults.add("upstream_connect_timeout_ms", "does not apply to udp sites, remove it", .{});
            if (cfg.upstream_idle_ttl_ms != null) try faults.add("upstream_idle_ttl_ms", "does not apply to udp sites, remove it", .{});

            // Datagram forwarding has no client connection to bound: a flow
            // is remembered by its address, and the flow table ages it out.
            if (cfg.client_timeout_ms != null) try faults.add("client_timeout_ms", "does not apply to udp sites, remove it", .{});
            if (cfg.client_conn_limit != null) try faults.add("client_conn_limit", "does not apply to udp sites, remove it", .{});

            // Datagram forwarding has no request to hold back and no
            // upstream connect to bound, so the gate would count nothing.
            if (cfg.process_limit != null) try faults.add("process_limit", "does not apply to udp sites, remove it", .{});
            if (cfg.process_queue_len != null) try faults.add("process_queue_len", "does not apply to udp sites, remove it", .{});
            if (cfg.process_queue_timeout_ms != null) try faults.add("process_queue_timeout_ms", "does not apply to udp sites, remove it", .{});

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

test "zix zixer: site cfg, a max recv buf outside the range faults and stays unset" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const content =
        "engine: http1\n" ++
        "port: 8080\n" ++
        "upstreams: 127.0.0.1:3000\n" ++
        "max_recv_buf: 512\n";

    var faults = fault.FaultList.init(arena.allocator());
    const cfg = try parse(arena.allocator(), content, &faults);

    try testing.expectEqual(@as(usize, 1), faults.slice().len);
    try testing.expectEqualStrings("max_recv_buf", faults.slice()[0].key);

    // Unset, so the site falls back to the main.cfg value rather than to a
    // number the file asked for and did not get.
    try testing.expectEqual(@as(?usize, null), cfg.max_recv_buf);
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

test "zix zixer: site cfg, cleartext non-http1 site rejects acme keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var h2_faults = fault.FaultList.init(arena.allocator());
    _ = try parse(arena.allocator(), "engine: http2\nport: 18899\nupstreams: 127.0.0.1:3000\nacme_webroot: /var/www/acme\n", &h2_faults);
    try testing.expectEqual(@as(usize, 1), h2_faults.slice().len);
    try testing.expectEqualStrings("acme_webroot", h2_faults.slice()[0].key);
    try testing.expectEqualStrings("needs tls: true or an http1 site", h2_faults.slice()[0].hint);

    // the same keys are fine on a cleartext http1 site (own listener) and
    // on a TLS site (port 80 companion).
    var h1_faults = fault.FaultList.init(arena.allocator());
    _ = try parse(arena.allocator(), "engine: http1\nport: 80\nupstreams: 127.0.0.1:3000\nacme_webroot: /var/www/acme\n", &h1_faults);
    try testing.expectEqual(@as(usize, 0), h1_faults.slice().len);
}

test "zix zixer: site cfg, upstream_timeout_ms parses and zero means no bound" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var faults = fault.FaultList.init(arena.allocator());
    const cfg = try parse(arena.allocator(), "engine: http1\nport: 18898\nupstreams: 127.0.0.1:3000\nupstream_timeout_ms: 5 * 1000\n", &faults);
    try testing.expectEqual(@as(usize, 0), faults.slice().len);
    try testing.expectEqual(@as(u32, 5000), cfg.upstream_timeout_ms.?);

    var off_faults = fault.FaultList.init(arena.allocator());
    const off = try parse(arena.allocator(), "engine: http1\nport: 18898\nupstreams: 127.0.0.1:3000\nupstream_timeout_ms: 0\n", &off_faults);
    try testing.expectEqual(@as(usize, 0), off_faults.slice().len);
    try testing.expectEqual(@as(u32, 0), off.upstream_timeout_ms.?);

    // Left out entirely, the edge takes its built-in default.
    var bare_faults = fault.FaultList.init(arena.allocator());
    const bare = try parse(arena.allocator(), "engine: http1\nport: 18898\nupstreams: 127.0.0.1:3000\n", &bare_faults);
    try testing.expectEqual(@as(usize, 0), bare_faults.slice().len);
    try testing.expectEqual(@as(?u32, null), bare.upstream_timeout_ms);
}

test "zix zixer: site cfg, upstream_timeout_ms is refused where it cannot apply" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var static_faults = fault.FaultList.init(arena.allocator());
    _ = try parse(arena.allocator(), "engine: http1\nport: 18898\npublic_dir: /var/www/app\nupstream_timeout_ms: 1000\n", &static_faults);
    try testing.expectEqual(@as(usize, 1), static_faults.slice().len);
    try testing.expectEqualStrings("upstream_timeout_ms", static_faults.slice()[0].key);
    try testing.expectEqualStrings("needs upstreams", static_faults.slice()[0].hint);

    var grpc_faults = fault.FaultList.init(arena.allocator());
    _ = try parse(arena.allocator(), "engine: grpc\nport: 18898\nupstreams: 127.0.0.1:3000\nupstream_timeout_ms: 1000\n", &grpc_faults);
    try testing.expectEqual(@as(usize, 1), grpc_faults.slice().len);
    try testing.expectEqualStrings("upstream_timeout_ms", grpc_faults.slice()[0].key);

    var udp_faults = fault.FaultList.init(arena.allocator());
    _ = try parse(arena.allocator(), "engine: udp\nport: 18898\nupstreams: 127.0.0.1:3000\nupstream_timeout_ms: 1000\n", &udp_faults);
    try testing.expectEqual(@as(usize, 1), udp_faults.slice().len);
    try testing.expectEqualStrings("upstream_timeout_ms", udp_faults.slice()[0].key);

    var negative_faults = fault.FaultList.init(arena.allocator());
    _ = try parse(arena.allocator(), "engine: http1\nport: 18898\nupstreams: 127.0.0.1:3000\nupstream_timeout_ms: 0 - 1\n", &negative_faults);
    try testing.expectEqual(@as(usize, 1), negative_faults.slice().len);
    try testing.expectEqualStrings("upstream_timeout_ms", negative_faults.slice()[0].key);
}

test "zix zixer: site cfg, the process gate keys parse and default to null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var faults = fault.FaultList.init(arena.allocator());
    const cfg = try parse(arena.allocator(), "engine: http1\nport: 18898\nupstreams: 127.0.0.1:3000\nprocess_limit: 32\nprocess_queue_len: 4 * 32\nprocess_queue_timeout_ms: 1500\n", &faults);

    try testing.expectEqual(@as(usize, 0), faults.slice().len);
    try testing.expectEqual(@as(usize, 32), cfg.process_limit.?);
    try testing.expectEqual(@as(usize, 128), cfg.process_queue_len.?);
    try testing.expectEqual(@as(u32, 1500), cfg.process_queue_timeout_ms.?);

    var bare_faults = fault.FaultList.init(arena.allocator());
    const bare = try parse(arena.allocator(), "engine: http1\nport: 18898\nupstreams: 127.0.0.1:3000\n", &bare_faults);

    try testing.expectEqual(@as(?usize, null), bare.process_limit);
    try testing.expectEqual(@as(?usize, null), bare.process_queue_len);
    try testing.expectEqual(@as(?u32, null), bare.process_queue_timeout_ms);
}

test "zix zixer: site cfg, a site may turn the daemon gate off for itself" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var faults = fault.FaultList.init(arena.allocator());
    const cfg = try parse(arena.allocator(), "engine: http1\nport: 18898\nupstreams: 127.0.0.1:3000\nprocess_limit: 0\n", &faults);

    try testing.expectEqual(@as(usize, 0), faults.slice().len);
    try testing.expectEqual(@as(usize, 0), cfg.process_limit.?);
}

test "zix zixer: site cfg, a site queue with the limit turned off faults" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var faults = fault.FaultList.init(arena.allocator());
    _ = try parse(arena.allocator(), "engine: http1\nport: 18898\nupstreams: 127.0.0.1:3000\nprocess_limit: 0\nprocess_queue_len: 8\n", &faults);

    try testing.expectEqual(@as(usize, 1), faults.slice().len);
    try testing.expectEqualStrings("process_queue_len", faults.slice()[0].key);
    try testing.expectEqualStrings("needs process_limit above 0, otherwise nothing ever queues", faults.slice()[0].hint);
}

test "zix zixer: site cfg, the process gate keys are refused where they cannot apply" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var static_faults = fault.FaultList.init(arena.allocator());
    _ = try parse(arena.allocator(), "engine: http1\nport: 18898\npublic_dir: /var/www/app\nprocess_limit: 8\n", &static_faults);
    try testing.expectEqual(@as(usize, 1), static_faults.slice().len);
    try testing.expectEqualStrings("process_limit", static_faults.slice()[0].key);
    try testing.expectEqualStrings("needs upstreams", static_faults.slice()[0].hint);

    var udp_faults = fault.FaultList.init(arena.allocator());
    _ = try parse(arena.allocator(), "engine: udp\nport: 18898\nupstreams: 127.0.0.1:3000\nprocess_limit: 8\nprocess_queue_len: 8\n", &udp_faults);
    try testing.expectEqual(@as(usize, 2), udp_faults.slice().len);
    try testing.expectEqualStrings("process_limit", udp_faults.slice()[0].key);
    try testing.expectEqualStrings("does not apply to udp sites, remove it", udp_faults.slice()[0].hint);
    try testing.expectEqualStrings("process_queue_len", udp_faults.slice()[1].key);

    var negative_faults = fault.FaultList.init(arena.allocator());
    _ = try parse(arena.allocator(), "engine: http1\nport: 18898\nupstreams: 127.0.0.1:3000\nprocess_queue_timeout_ms: 0 - 1\n", &negative_faults);
    try testing.expectEqual(@as(usize, 1), negative_faults.slice().len);
    try testing.expectEqualStrings("process_queue_timeout_ms", negative_faults.slice()[0].key);
}

test "zix zixer: site cfg, a grpc site may carry the process gate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var faults = fault.FaultList.init(arena.allocator());
    const cfg = try parse(arena.allocator(), "engine: grpc\nport: 18898\nupstreams: 127.0.0.1:3000\nprocess_limit: 16\n", &faults);

    try testing.expectEqual(@as(usize, 0), faults.slice().len);
    try testing.expectEqual(@as(usize, 16), cfg.process_limit.?);
}

test "zix zixer: site cfg, the static cache window parses and defaults to null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var bare_faults = fault.FaultList.init(arena.allocator());
    const bare = try parse(arena.allocator(), "engine: http1\nport: 18898\npublic_dir: /var/www/app\n", &bare_faults);
    try testing.expectEqual(@as(usize, 0), bare_faults.slice().len);
    try testing.expectEqual(@as(?u32, null), bare.public_dir_cache_ttl_ms);

    var set_faults = fault.FaultList.init(arena.allocator());
    const set = try parse(
        arena.allocator(),
        "engine: http1\nport: 18898\npublic_dir: /var/www/app\npublic_dir_cache_ttl_ms: 5 * 1000\n",
        &set_faults,
    );
    try testing.expectEqual(@as(usize, 0), set_faults.slice().len);
    try testing.expectEqual(@as(u32, 5000), set.public_dir_cache_ttl_ms.?);

    // 0 is a site turning the cache off while the daemon leaves it on.
    var off_faults = fault.FaultList.init(arena.allocator());
    const off = try parse(
        arena.allocator(),
        "engine: http1\nport: 18898\npublic_dir: /var/www/app\npublic_dir_cache_ttl_ms: 0\n",
        &off_faults,
    );
    try testing.expectEqual(@as(usize, 0), off_faults.slice().len);
    try testing.expectEqual(@as(u32, 0), off.public_dir_cache_ttl_ms.?);
}

test "zix zixer: site cfg, the static cache window is refused where it cannot apply" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var proxy_faults = fault.FaultList.init(arena.allocator());
    _ = try parse(
        arena.allocator(),
        "engine: http1\nport: 18898\nupstreams: 127.0.0.1:3000\npublic_dir_cache_ttl_ms: 5000\n",
        &proxy_faults,
    );
    try testing.expectEqual(@as(usize, 1), proxy_faults.slice().len);
    try testing.expectEqualStrings("public_dir_cache_ttl_ms", proxy_faults.slice()[0].key);
    try testing.expectEqualStrings("needs public_dir", proxy_faults.slice()[0].hint);

    var grpc_faults = fault.FaultList.init(arena.allocator());
    _ = try parse(
        arena.allocator(),
        "engine: grpc\nport: 18898\nupstreams: 127.0.0.1:3000\npublic_dir_cache_ttl_ms: 5000\n",
        &grpc_faults,
    );
    try testing.expectEqual(@as(usize, 2), grpc_faults.slice().len);
    try testing.expectEqualStrings("public_dir_cache_ttl_ms", grpc_faults.slice()[0].key);
    try testing.expectEqualStrings("needs public_dir", grpc_faults.slice()[0].hint);
    try testing.expectEqualStrings("public_dir_cache_ttl_ms", grpc_faults.slice()[1].key);
    try testing.expectEqualStrings("not supported on grpc sites, remove it", grpc_faults.slice()[1].hint);

    var udp_faults = fault.FaultList.init(arena.allocator());
    _ = try parse(
        arena.allocator(),
        "engine: udp\nport: 18898\nupstreams: 127.0.0.1:3000\npublic_dir_cache_ttl_ms: 5000\n",
        &udp_faults,
    );
    try testing.expectEqual(@as(usize, 2), udp_faults.slice().len);
    try testing.expectEqualStrings("public_dir_cache_ttl_ms", udp_faults.slice()[1].key);
    try testing.expectEqualStrings("does not apply to udp sites, remove it", udp_faults.slice()[1].hint);

    var over_faults = fault.FaultList.init(arena.allocator());
    _ = try parse(
        arena.allocator(),
        "engine: http1\nport: 18898\npublic_dir: /var/www/app\npublic_dir_cache_ttl_ms: 60 * 60 * 1000 + 1\n",
        &over_faults,
    );
    try testing.expectEqual(@as(usize, 1), over_faults.slice().len);
    try testing.expectEqualStrings("public_dir_cache_ttl_ms", over_faults.slice()[0].key);
}

test "zix zixer: site cfg, the entry count says where it belongs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // The table is one per daemon, so a site cannot resize it. The hint points
    // at main.cfg rather than reading as a typo.
    var faults = fault.FaultList.init(arena.allocator());
    _ = try parse(
        arena.allocator(),
        "engine: http1\nport: 18898\npublic_dir: /var/www/app\npublic_dir_cache_max_entries: 64\n",
        &faults,
    );

    try testing.expectEqual(@as(usize, 1), faults.slice().len);
    try testing.expectEqualStrings("public_dir_cache_max_entries", faults.slice()[0].key);
    try testing.expectEqualStrings("set it in main.cfg, the cache table is one per daemon and every site shares it", faults.slice()[0].hint);
}

test "zix zixer: site cfg, the client bound keys parse and default to null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var faults = fault.FaultList.init(arena.allocator());
    const cfg = try parse(
        arena.allocator(),
        "engine: http1\nport: 18898\nupstreams: 127.0.0.1:3000\nclient_timeout_ms: 30 * 1000\nclient_conn_limit: 2 * 1024\n",
        &faults,
    );

    try testing.expectEqual(@as(usize, 0), faults.slice().len);
    try testing.expectEqual(@as(u32, 30_000), cfg.client_timeout_ms.?);
    try testing.expectEqual(@as(usize, 2048), cfg.client_conn_limit.?);

    // 0 is a site turning the bound off while the daemon leaves it on.
    var off_faults = fault.FaultList.init(arena.allocator());
    const off = try parse(arena.allocator(), "engine: http1\nport: 18898\nupstreams: 127.0.0.1:3000\nclient_timeout_ms: 0\n", &off_faults);
    try testing.expectEqual(@as(usize, 0), off_faults.slice().len);
    try testing.expectEqual(@as(u32, 0), off.client_timeout_ms.?);

    var bare_faults = fault.FaultList.init(arena.allocator());
    const bare = try parse(arena.allocator(), "engine: http1\nport: 18898\nupstreams: 127.0.0.1:3000\n", &bare_faults);
    try testing.expectEqual(@as(?u32, null), bare.client_timeout_ms);
    try testing.expectEqual(@as(?usize, null), bare.client_conn_limit);
}

test "zix zixer: site cfg, the client bound keys are refused where they cannot apply" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // A limit with the bound switched off in the same file is dead config:
    // nothing is tracked, so no slot is ever taken.
    var dead_faults = fault.FaultList.init(arena.allocator());
    _ = try parse(
        arena.allocator(),
        "engine: http1\nport: 18898\nupstreams: 127.0.0.1:3000\nclient_timeout_ms: 0\nclient_conn_limit: 64\n",
        &dead_faults,
    );
    try testing.expectEqual(@as(usize, 1), dead_faults.slice().len);
    try testing.expectEqualStrings("client_conn_limit", dead_faults.slice()[0].key);
    try testing.expectEqualStrings("needs client_timeout_ms above 0, otherwise nothing is tracked", dead_faults.slice()[0].hint);

    var udp_faults = fault.FaultList.init(arena.allocator());
    _ = try parse(
        arena.allocator(),
        "engine: udp\nport: 18898\nupstreams: 127.0.0.1:3000\nclient_timeout_ms: 1000\nclient_conn_limit: 64\n",
        &udp_faults,
    );
    try testing.expectEqual(@as(usize, 2), udp_faults.slice().len);
    try testing.expectEqualStrings("client_timeout_ms", udp_faults.slice()[0].key);
    try testing.expectEqualStrings("does not apply to udp sites, remove it", udp_faults.slice()[0].hint);
    try testing.expectEqualStrings("client_conn_limit", udp_faults.slice()[1].key);

    // A quic connection has no socket of its own for the sweep to cut, so an
    // http3 site refuses both keys rather than accepting a bound it can never
    // act on.
    var h3_faults = fault.FaultList.init(arena.allocator());
    _ = try parse(
        arena.allocator(),
        "engine: http3\nport: 18898\ntls: true\ntls_cert: /tmp/c.pem\ntls_key: /tmp/k.pem\nupstreams: 127.0.0.1:3000\nclient_timeout_ms: 1000\nclient_conn_limit: 64\n",
        &h3_faults,
    );
    try testing.expectEqual(@as(usize, 2), h3_faults.slice().len);
    try testing.expectEqualStrings("client_timeout_ms", h3_faults.slice()[0].key);
    try testing.expectEqualStrings("not supported on http3 sites, remove it", h3_faults.slice()[0].hint);
    try testing.expectEqualStrings("client_conn_limit", h3_faults.slice()[1].key);

    // A table with no slot would refuse every connection, which is not what
    // turning the bound off means.
    var zero_faults = fault.FaultList.init(arena.allocator());
    _ = try parse(
        arena.allocator(),
        "engine: http1\nport: 18898\nupstreams: 127.0.0.1:3000\nclient_timeout_ms: 1000\nclient_conn_limit: 0\n",
        &zero_faults,
    );
    try testing.expectEqual(@as(usize, 1), zero_faults.slice().len);
    try testing.expectEqualStrings("client_conn_limit", zero_faults.slice()[0].key);

    var over_buf: [192]u8 = undefined;
    const over_content = try std.fmt.bufPrint(
        &over_buf,
        "engine: http1\nport: 18898\nupstreams: 127.0.0.1:3000\nclient_timeout_ms: {d}\nclient_conn_limit: {d}\n",
        .{ deadline_table.MAX_TIMEOUT_MS + 1, deadline_table.MAX_SLOTS + 1 },
    );

    var over_faults = fault.FaultList.init(arena.allocator());
    const over = try parse(arena.allocator(), over_content, &over_faults);
    try testing.expectEqual(@as(usize, 2), over_faults.slice().len);
    try testing.expectEqual(@as(?u32, null), over.client_timeout_ms);
    try testing.expectEqual(@as(?usize, null), over.client_conn_limit);
}

test "zix zixer: site cfg, the upstream connect and idle keys parse and default to null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var faults = fault.FaultList.init(arena.allocator());
    const cfg = try parse(
        arena.allocator(),
        "engine: http1\nport: 18898\nupstreams: 127.0.0.1:3000\nupstream_connect_timeout_ms: 5 * 1000\nupstream_idle_ttl_ms: 60 * 1000\n",
        &faults,
    );

    try testing.expectEqual(@as(usize, 0), faults.slice().len);
    try testing.expectEqual(@as(u32, 5000), cfg.upstream_connect_timeout_ms.?);
    try testing.expectEqual(@as(u32, 60_000), cfg.upstream_idle_ttl_ms.?);

    // 0 on each: no connect bound, and no connection kept between requests.
    var off_faults = fault.FaultList.init(arena.allocator());
    const off = try parse(
        arena.allocator(),
        "engine: http1\nport: 18898\nupstreams: 127.0.0.1:3000\nupstream_connect_timeout_ms: 0\nupstream_idle_ttl_ms: 0\n",
        &off_faults,
    );
    try testing.expectEqual(@as(usize, 0), off_faults.slice().len);
    try testing.expectEqual(@as(u32, 0), off.upstream_connect_timeout_ms.?);
    try testing.expectEqual(@as(u32, 0), off.upstream_idle_ttl_ms.?);

    var bare_faults = fault.FaultList.init(arena.allocator());
    const bare = try parse(arena.allocator(), "engine: http1\nport: 18898\nupstreams: 127.0.0.1:3000\n", &bare_faults);
    try testing.expectEqual(@as(?u32, null), bare.upstream_connect_timeout_ms);
    try testing.expectEqual(@as(?u32, null), bare.upstream_idle_ttl_ms);
}

test "zix zixer: site cfg, the upstream connect and idle keys are refused where they cannot apply" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var static_faults = fault.FaultList.init(arena.allocator());
    _ = try parse(
        arena.allocator(),
        "engine: http1\nport: 18898\npublic_dir: /var/www/app\nupstream_connect_timeout_ms: 1000\nupstream_idle_ttl_ms: 1000\n",
        &static_faults,
    );
    try testing.expectEqual(@as(usize, 2), static_faults.slice().len);
    try testing.expectEqualStrings("upstream_connect_timeout_ms", static_faults.slice()[0].key);
    try testing.expectEqualStrings("needs upstreams", static_faults.slice()[0].hint);
    try testing.expectEqualStrings("upstream_idle_ttl_ms", static_faults.slice()[1].key);

    // The grpc leg holds one h2 connection for the exchange instead of
    // parking it, so only the age is refused there. The connect is the same
    // dial every other engine makes.
    var grpc_faults = fault.FaultList.init(arena.allocator());
    const grpc = try parse(
        arena.allocator(),
        "engine: grpc\nport: 18898\nupstreams: 127.0.0.1:3000\nupstream_connect_timeout_ms: 1000\nupstream_idle_ttl_ms: 1000\n",
        &grpc_faults,
    );
    try testing.expectEqual(@as(usize, 1), grpc_faults.slice().len);
    try testing.expectEqualStrings("upstream_idle_ttl_ms", grpc_faults.slice()[0].key);
    try testing.expectEqualStrings("not supported on grpc sites, remove it", grpc_faults.slice()[0].hint);
    try testing.expectEqual(@as(u32, 1000), grpc.upstream_connect_timeout_ms.?);

    var udp_faults = fault.FaultList.init(arena.allocator());
    _ = try parse(
        arena.allocator(),
        "engine: udp\nport: 18898\nupstreams: 127.0.0.1:3000\nupstream_idle_ttl_ms: 1000\n",
        &udp_faults,
    );
    try testing.expectEqual(@as(usize, 1), udp_faults.slice().len);
    try testing.expectEqualStrings("upstream_idle_ttl_ms", udp_faults.slice()[0].key);
    try testing.expectEqualStrings("does not apply to udp sites, remove it", udp_faults.slice()[0].hint);

    var over_buf: [224]u8 = undefined;
    const over_content = try std.fmt.bufPrint(
        &over_buf,
        "engine: http1\nport: 18898\nupstreams: 127.0.0.1:3000\nupstream_connect_timeout_ms: {d}\nupstream_idle_ttl_ms: {d}\n",
        .{ upstream_conn.MAX_CONNECT_TIMEOUT_MS + 1, upstream_conn.MAX_IDLE_TTL_MS + 1 },
    );

    var over_faults = fault.FaultList.init(arena.allocator());
    const over = try parse(arena.allocator(), over_content, &over_faults);
    try testing.expectEqual(@as(usize, 2), over_faults.slice().len);
    try testing.expectEqual(@as(?u32, null), over.upstream_connect_timeout_ms);
    try testing.expectEqual(@as(?u32, null), over.upstream_idle_ttl_ms);
}
