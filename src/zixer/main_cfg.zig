//! zixer main.cfg schema: parse, validate, defaults

const std = @import("std");
const builtin = @import("builtin");
const zix = @import("zix");

const cfg_scanner = @import("cfg_scanner.zig");
const fault = @import("fault.zig");

/// Dispatch enum is the zix one, so the daemon hands it straight to the engines.
pub const Dispatch = zix.Http1.DispatchModel;

/// Parsed main.cfg with every default applied.
pub const MainCfg = struct {
    workers: usize = 1,
    dispatch: Dispatch = .ASYNC,
    logs_dir: []const u8 = "",
    sites_dir: []const u8 = "",
    kernel_backlog: u31 = 1024,
    max_recv_buf: usize = 1472,
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
                if (value < 1) {
                    try faults.add(entry.key, "must be at least 1", .{});
                    continue;
                }

                cfg.max_recv_buf = @intCast(value);
            },
        }
    }

    if (!seen.contains(.logs_dir)) cfg.logs_dir = try std.fs.path.join(arena, &.{ root_path, "logs" });
    if (!seen.contains(.sites_dir)) cfg.sites_dir = try std.fs.path.join(arena, &.{ root_path, "sites" });

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
    try std.testing.expectEqual(@as(usize, 1472), cfg.max_recv_buf);

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

test "zix zixer: main cfg, dispatch names round trip" {
    try std.testing.expectEqual(Dispatch.ASYNC, parseDispatch("async").?);
    try std.testing.expectEqual(Dispatch.EPOLL, parseDispatch("epoll").?);
    try std.testing.expectEqual(Dispatch.URING, parseDispatch("uring").?);
    try std.testing.expectEqual(@as(?Dispatch, null), parseDispatch("ASYNC"));

    try std.testing.expectEqualStrings("async", dispatchName(.ASYNC));
    try std.testing.expectEqualStrings("epoll", dispatchName(.EPOLL));
    try std.testing.expectEqualStrings("uring", dispatchName(.URING));
}
