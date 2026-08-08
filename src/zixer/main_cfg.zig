//! zixer main.cfg schema: parse, validate, defaults

const std = @import("std");
const builtin = @import("builtin");
const zix = @import("zix");

const cfg_scanner = @import("cfg_scanner.zig");
const conn_buffer = @import("conn_buffer.zig");
const fault = @import("fault.zig");
const process_gate = @import("process_gate.zig");

/// Dispatch enum is the zix one, so the daemon hands it straight to the engines.
pub const Dispatch = zix.Http1.DispatchModel;

/// Parsed main.cfg with every default applied.
pub const MainCfg = struct {
    workers: usize = 1,
    dispatch: Dispatch = .ASYNC,
    logs_dir: []const u8 = "",
    sites_dir: []const u8 = "",
    kernel_backlog: u31 = 1024,
    max_recv_buf: usize = conn_buffer.DEFAULT_BYTES,
    /// Requests one site may have running upstream at once. 0 is the gate
    /// off, which is what a daemon that never asked for one runs with.
    process_limit: usize = 0,
    /// Requests that may wait for a process slot. 0 refuses the moment the
    /// limit is reached, which is shed-instead-of-queue.
    process_queue_len: usize = 0,
    /// How long a waiting request holds on before the edge answers 504.
    process_queue_timeout_ms: u32 = process_gate.DEFAULT_TIMEOUT_MS,
};

/// Known main.cfg keys. Field names mirror the cfg key strings exactly so
/// stringToEnum does the lookup, hence lower_case here.
const Key = enum {
    workers,
    dispatch,
    logs_dir,
    sites_dir,
    kernel_backlog,
    max_recv_buf,
    process_limit,
    process_queue_len,
    process_queue_timeout_ms,
};

/// Parse and validate main.cfg content.
///
/// Note:
/// - Faults never abort the parse: every problem lands in faults with a fix
///   hint, and the returned config keeps the default for a bad field.
/// - String values are slices into content, so content must outlive the result.
///
/// Param:
/// arena - std.mem.Allocator (owns the logs_dir/sites_dir defaults)
/// content - []const u8 (main.cfg bytes)
/// root_path - []const u8 (resolved zixer root dir, builds the dir defaults)
/// available_threads - usize (cpu thread count bounding workers)
/// faults - *fault.FaultList (collects every validation problem)
///
/// Return:
/// - MainCfg with defaults applied where the file was silent or wrong
pub fn parse(
    arena: std.mem.Allocator,
    content: []const u8,
    root_path: []const u8,
    available_threads: usize,
    faults: *fault.FaultList,
) !MainCfg {
    var cfg = MainCfg{};
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
            .workers => {
                const value = try fault.evalNumber(faults, entry) orelse continue;
                const workers_count = std.math.cast(usize, value) orelse {
                    try faults.add(entry.key, "must be 0 or a positive count", .{});
                    continue;
                };

                if (workers_count > available_threads) {
                    try faults.add(entry.key, "workers exceed from available threads ({d}), set to 0 or 1", .{available_threads});
                    continue;
                }

                cfg.workers = workers_count;
            },
            .dispatch => {
                const model = parseDispatch(entry.value) orelse {
                    try faults.add(entry.key, "unknown value '{s}', use async, epoll, or uring", .{entry.value});
                    continue;
                };

                if (comptime builtin.os.tag != .linux) {
                    if (model != .ASYNC) {
                        try faults.add(entry.key, "{s} needs linux, use async on this platform", .{entry.value});
                        continue;
                    }
                }

                cfg.dispatch = model;
            },
            .logs_dir => cfg.logs_dir = entry.value,
            .sites_dir => cfg.sites_dir = entry.value,
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
        }
    }

    if (!seen.contains(.logs_dir)) cfg.logs_dir = try std.fs.path.join(arena, &.{ root_path, "logs" });
    if (!seen.contains(.sites_dir)) cfg.sites_dir = try std.fs.path.join(arena, &.{ root_path, "sites" });

    // A waiting room with nothing to wait for is a config mistake, not a
    // setting: without a limit no request ever queues, so the line would
    // silently do nothing.
    if (cfg.process_limit == 0 and cfg.process_queue_len > 0) {
        try faults.add("process_queue_len", "needs process_limit above 0, otherwise nothing ever queues", .{});
        cfg.process_queue_len = 0;
    }

    return cfg;
}

/// Cfg spelling to dispatch value, null when unknown.
fn parseDispatch(value: []const u8) ?Dispatch {
    if (std.mem.eql(u8, value, "async")) return .ASYNC;
    if (std.mem.eql(u8, value, "epoll")) return .EPOLL;
    if (std.mem.eql(u8, value, "uring")) return .URING;

    return null;
}

/// Lowercase cfg spelling of a dispatch value, for status output.
pub fn dispatchName(model: Dispatch) []const u8 {
    return switch (model) {
        .ASYNC => "async",
        .EPOLL => "epoll",
        .URING => "uring",
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix zixer: main cfg, empty content keeps defaults with dirs from root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var faults = fault.FaultList.init(arena.allocator());
    const cfg = try parse(arena.allocator(), "", "/srv/zixer", 8, &faults);

    try std.testing.expectEqual(@as(usize, 0), faults.slice().len);
    try std.testing.expectEqual(@as(usize, 1), cfg.workers);
    try std.testing.expectEqual(Dispatch.ASYNC, cfg.dispatch);
    try std.testing.expectEqual(@as(u31, 1024), cfg.kernel_backlog);
    try std.testing.expectEqual(conn_buffer.DEFAULT_BYTES, cfg.max_recv_buf);

    const expected_logs = try std.fs.path.join(arena.allocator(), &.{ "/srv/zixer", "logs" });
    const expected_sites = try std.fs.path.join(arena.allocator(), &.{ "/srv/zixer", "sites" });
    try std.testing.expectEqualStrings(expected_logs, cfg.logs_dir);
    try std.testing.expectEqualStrings(expected_sites, cfg.sites_dir);
}

test "zix zixer: main cfg, full valid content with math values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const content =
        "workers: 0\n" ++
        "dispatch: uring\n" ++
        "logs_dir: /var/log/zixer\n" ++
        "sites_dir: /etc/zixer/sites\n" ++
        "kernel_backlog: 2 * 1024\n" ++
        "max_recv_buf: 16 * 1024\n";

    var faults = fault.FaultList.init(arena.allocator());
    const cfg = try parse(arena.allocator(), content, "/srv/zixer", 8, &faults);

    // epoll and uring are Linux dispatch models, elsewhere the same line faults.
    if (comptime builtin.os.tag == .linux) {
        try std.testing.expectEqual(@as(usize, 0), faults.slice().len);
        try std.testing.expectEqual(Dispatch.URING, cfg.dispatch);
    } else {
        try std.testing.expectEqual(@as(usize, 1), faults.slice().len);
        try std.testing.expectEqualStrings("dispatch", faults.slice()[0].key);
        try std.testing.expectEqual(Dispatch.ASYNC, cfg.dispatch);
    }

    try std.testing.expectEqual(@as(usize, 0), cfg.workers);
    try std.testing.expectEqualStrings("/var/log/zixer", cfg.logs_dir);
    try std.testing.expectEqualStrings("/etc/zixer/sites", cfg.sites_dir);
    try std.testing.expectEqual(@as(u31, 2048), cfg.kernel_backlog);
    try std.testing.expectEqual(@as(usize, 16384), cfg.max_recv_buf);
}

test "zix zixer: main cfg, workers above available threads faults and keeps default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var faults = fault.FaultList.init(arena.allocator());
    const cfg = try parse(arena.allocator(), "workers: 64\n", "/srv/zixer", 8, &faults);

    try std.testing.expectEqual(@as(usize, 1), faults.slice().len);
    try std.testing.expectEqualStrings("workers", faults.slice()[0].key);
    try std.testing.expectEqualStrings("workers exceed from available threads (8), set to 0 or 1", faults.slice()[0].hint);
    try std.testing.expectEqual(@as(usize, 1), cfg.workers);
}

test "zix zixer: main cfg, unknown and duplicate keys fault" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const content =
        "wrokers: 2\n" ++
        "workers: 2\n" ++
        "workers: 3\n";

    var faults = fault.FaultList.init(arena.allocator());
    const cfg = try parse(arena.allocator(), content, "/srv/zixer", 8, &faults);

    try std.testing.expectEqual(@as(usize, 2), faults.slice().len);
    try std.testing.expectEqualStrings("wrokers", faults.slice()[0].key);
    try std.testing.expectEqualStrings("unknown key, remove it or fix the typo", faults.slice()[0].hint);
    try std.testing.expectEqualStrings("duplicate key, keep one line", faults.slice()[1].hint);
    try std.testing.expectEqual(@as(usize, 2), cfg.workers);
}

test "zix zixer: main cfg, bad dispatch and bad math fault with hints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const content =
        "dispatch: turbo\n" ++
        "kernel_backlog: 10 / 4\n" ++
        "no colon line\n";

    var faults = fault.FaultList.init(arena.allocator());
    const cfg = try parse(arena.allocator(), content, "/srv/zixer", 8, &faults);

    try std.testing.expectEqual(@as(usize, 3), faults.slice().len);
    try std.testing.expectEqualStrings("unknown value 'turbo', use async, epoll, or uring", faults.slice()[0].hint);
    try std.testing.expectEqualStrings("division leaves a remainder, config values must be exact", faults.slice()[1].hint);
    try std.testing.expectEqualStrings("no colon line", faults.slice()[2].key);
    try std.testing.expectEqual(Dispatch.ASYNC, cfg.dispatch);
    try std.testing.expectEqual(@as(u31, 1024), cfg.kernel_backlog);
}

test "zix zixer: main cfg, a max recv buf outside the range faults and keeps the default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const content = "max_recv_buf: 64\n";

    var faults = fault.FaultList.init(arena.allocator());
    const cfg = try parse(arena.allocator(), content, "/srv/zixer", 8, &faults);

    try std.testing.expectEqual(@as(usize, 1), faults.slice().len);
    try std.testing.expectEqualStrings("max_recv_buf", faults.slice()[0].key);
    try std.testing.expect(std.mem.indexOf(u8, faults.slice()[0].hint, "bytes") != null);
    try std.testing.expectEqual(conn_buffer.DEFAULT_BYTES, cfg.max_recv_buf);
}

test "zix zixer: main cfg, a max recv buf above the ceiling faults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var content_buf: [64]u8 = undefined;
    const content = try std.fmt.bufPrint(&content_buf, "max_recv_buf: {d}\n", .{conn_buffer.MAX_BYTES + 1});

    var faults = fault.FaultList.init(arena.allocator());
    const cfg = try parse(arena.allocator(), content, "/srv/zixer", 8, &faults);

    try std.testing.expectEqual(@as(usize, 1), faults.slice().len);
    try std.testing.expectEqual(conn_buffer.DEFAULT_BYTES, cfg.max_recv_buf);
}

test "zix zixer: main cfg, the range ends are both accepted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var low_buf: [64]u8 = undefined;
    const low_content = try std.fmt.bufPrint(&low_buf, "max_recv_buf: {d}\n", .{conn_buffer.MIN_BYTES});
    var low_faults = fault.FaultList.init(arena.allocator());
    const low = try parse(arena.allocator(), low_content, "/srv/zixer", 8, &low_faults);

    var high_buf: [64]u8 = undefined;
    const high_content = try std.fmt.bufPrint(&high_buf, "max_recv_buf: {d}\n", .{conn_buffer.MAX_BYTES});
    var high_faults = fault.FaultList.init(arena.allocator());
    const high = try parse(arena.allocator(), high_content, "/srv/zixer", 8, &high_faults);

    try std.testing.expectEqual(@as(usize, 0), low_faults.slice().len);
    try std.testing.expectEqual(conn_buffer.MIN_BYTES, low.max_recv_buf);
    try std.testing.expectEqual(@as(usize, 0), high_faults.slice().len);
    try std.testing.expectEqual(conn_buffer.MAX_BYTES, high.max_recv_buf);
}

test "zix zixer: main cfg, the process gate defaults to off" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var faults = fault.FaultList.init(arena.allocator());
    const cfg = try parse(arena.allocator(), "", "/srv/zixer", 8, &faults);

    try std.testing.expectEqual(@as(usize, 0), faults.slice().len);
    try std.testing.expectEqual(@as(usize, 0), cfg.process_limit);
    try std.testing.expectEqual(@as(usize, 0), cfg.process_queue_len);
    try std.testing.expectEqual(process_gate.DEFAULT_TIMEOUT_MS, cfg.process_queue_timeout_ms);
}

test "zix zixer: main cfg, a full process gate parses with math values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const content =
        "process_limit: 64\n" ++
        "process_queue_len: 4 * 64\n" ++
        "process_queue_timeout_ms: 2 * 1000\n";

    var faults = fault.FaultList.init(arena.allocator());
    const cfg = try parse(arena.allocator(), content, "/srv/zixer", 8, &faults);

    try std.testing.expectEqual(@as(usize, 0), faults.slice().len);
    try std.testing.expectEqual(@as(usize, 64), cfg.process_limit);
    try std.testing.expectEqual(@as(usize, 256), cfg.process_queue_len);
    try std.testing.expectEqual(@as(u32, 2000), cfg.process_queue_timeout_ms);
}

test "zix zixer: main cfg, a queue with no limit faults and is turned off" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var faults = fault.FaultList.init(arena.allocator());
    const cfg = try parse(arena.allocator(), "process_queue_len: 32\n", "/srv/zixer", 8, &faults);

    try std.testing.expectEqual(@as(usize, 1), faults.slice().len);
    try std.testing.expectEqualStrings("process_queue_len", faults.slice()[0].key);
    try std.testing.expectEqualStrings("needs process_limit above 0, otherwise nothing ever queues", faults.slice()[0].hint);
    try std.testing.expectEqual(@as(usize, 0), cfg.process_queue_len);
}

test "zix zixer: main cfg, a limit with no queue is a valid shedding site" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var faults = fault.FaultList.init(arena.allocator());
    const cfg = try parse(arena.allocator(), "process_limit: 8\n", "/srv/zixer", 8, &faults);

    try std.testing.expectEqual(@as(usize, 0), faults.slice().len);
    try std.testing.expectEqual(@as(usize, 8), cfg.process_limit);
    try std.testing.expectEqual(@as(usize, 0), cfg.process_queue_len);
}

test "zix zixer: main cfg, a zero queue timeout faults and keeps the default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var faults = fault.FaultList.init(arena.allocator());
    const cfg = try parse(arena.allocator(), "process_queue_timeout_ms: 0\n", "/srv/zixer", 8, &faults);

    try std.testing.expectEqual(@as(usize, 1), faults.slice().len);
    try std.testing.expectEqualStrings("process_queue_timeout_ms", faults.slice()[0].key);
    try std.testing.expectEqual(process_gate.DEFAULT_TIMEOUT_MS, cfg.process_queue_timeout_ms);
}

test "zix zixer: main cfg, process gate values above their ceilings fault" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var content_buf: [160]u8 = undefined;
    const content = try std.fmt.bufPrint(&content_buf, "process_limit: {d}\nprocess_queue_len: {d}\nprocess_queue_timeout_ms: {d}\n", .{
        process_gate.MAX_SLOTS + 1,
        process_gate.MAX_SLOTS + 1,
        process_gate.MAX_TIMEOUT_MS + 1,
    });

    var faults = fault.FaultList.init(arena.allocator());
    const cfg = try parse(arena.allocator(), content, "/srv/zixer", 8, &faults);

    try std.testing.expectEqual(@as(usize, 3), faults.slice().len);
    try std.testing.expectEqual(@as(usize, 0), cfg.process_limit);
    try std.testing.expectEqual(@as(usize, 0), cfg.process_queue_len);
    try std.testing.expectEqual(process_gate.DEFAULT_TIMEOUT_MS, cfg.process_queue_timeout_ms);
}

test "zix zixer: main cfg, the process gate ceilings are accepted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var content_buf: [160]u8 = undefined;
    const content = try std.fmt.bufPrint(&content_buf, "process_limit: {d}\nprocess_queue_len: {d}\nprocess_queue_timeout_ms: {d}\n", .{
        process_gate.MAX_SLOTS,
        process_gate.MAX_SLOTS,
        process_gate.MAX_TIMEOUT_MS,
    });

    var faults = fault.FaultList.init(arena.allocator());
    const cfg = try parse(arena.allocator(), content, "/srv/zixer", 8, &faults);

    try std.testing.expectEqual(@as(usize, 0), faults.slice().len);
    try std.testing.expectEqual(process_gate.MAX_SLOTS, cfg.process_limit);
    try std.testing.expectEqual(process_gate.MAX_SLOTS, cfg.process_queue_len);
    try std.testing.expectEqual(process_gate.MAX_TIMEOUT_MS, cfg.process_queue_timeout_ms);
}

test "zix zixer: main cfg, dispatch names round trip" {
    try std.testing.expectEqual(Dispatch.ASYNC, parseDispatch("async").?);
    try std.testing.expectEqual(Dispatch.EPOLL, parseDispatch("epoll").?);
    try std.testing.expectEqual(Dispatch.URING, parseDispatch("uring").?);
    try std.testing.expectEqual(@as(?Dispatch, null), parseDispatch("ASYNC"));

    try std.testing.expectEqualStrings("async", dispatchName(.ASYNC));
    try std.testing.expectEqualStrings("epoll", dispatchName(.EPOLL));
    try std.testing.expectEqualStrings("uring", dispatchName(.URING));
}
