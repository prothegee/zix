//! Integration tests: zix.Logger file writing, format, and flush.
//! Each test uses a unique subdirectory under .zig-cache/tmp/zix-logger-test/
//! to avoid cross-test interference.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

fn currentDateBuf() [10]u8 {
    var spec: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &spec);
    const secs: u64 = if (spec.sec >= 0) @intCast(spec.sec) else 0;

    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = secs };
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    var buf: [10]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
    }) catch {};
    return buf;
}

// Creates all components of path using mkdirat at each prefix boundary.
// Mirrors the caller responsibility pattern: the logger no longer creates save_path.
fn ensureDirAll(path: []const u8) void {
    var buf: [512:0]u8 = undefined;
    var i: usize = 0;
    while (i <= path.len) : (i += 1) {
        const at_sep = i < path.len and path[i] == '/';
        const at_end = i == path.len;
        if ((at_sep or at_end) and i > 0) {
            const prefix = std.fmt.bufPrintZ(&buf, "{s}", .{path[0..i]}) catch continue;
            _ = std.posix.system.mkdirat(@as(i32, std.posix.AT.FDCWD), prefix, 0o755);
        }
    }
}

fn readLogFile(save_path: []const u8, date: *const [10]u8, save_file: []const u8, out: []u8) usize {
    var path_buf: [512]u8 = undefined;
    const fp = std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}-000000.log", .{
        save_path, date, save_file,
    }) catch return 0;

    const fd = std.posix.openat(
        @as(std.posix.fd_t, std.posix.AT.FDCWD),
        fp,
        .{ .ACCMODE = .RDONLY },
        0,
    ) catch return 0;
    defer _ = std.posix.system.close(fd);

    const rc = std.posix.system.read(fd, out.ptr, out.len);
    const n: usize = if (std.posix.errno(rc) == .SUCCESS) @intCast(rc) else 0;
    return n;
}

// --------------------------------------------------------- //

test "zix integration: Logger.system() writes line to file" {
    const allocator = std.testing.allocator;
    const save_path = ".zig-cache/tmp/zix-logger-test/system";
    ensureDirAll(save_path);

    var logger = try zix.Logger.init(allocator, .{
        .save_path = save_path,
        .save_file = "log",
        .save_min_level = .DEBUG,
        .max_lines = 1_000_000,
    });
    defer logger.deinit();

    logger.system(.INFO, "test", "hello {s}", .{"world"});
    logger.flush();

    const date = currentDateBuf();
    var buf: [4096]u8 = undefined;
    const n = readLogFile(save_path, &date, "log", &buf);

    try std.testing.expect(n > 0);
    const content = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, content, "[test]") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "hello world") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "INFO ") != null);
}

test "zix integration: Logger.access() writes line to file" {
    const allocator = std.testing.allocator;
    const save_path = ".zig-cache/tmp/zix-logger-test/access";
    ensureDirAll(save_path);

    var logger = try zix.Logger.init(allocator, .{
        .save_path = save_path,
        .save_file = "log",
        .save_min_level = .DEBUG,
        .max_lines = 1_000_000,
    });
    defer logger.deinit();

    logger.access("GET", "/api/users", 200, 512, "TestAgent/1.0", "http://example.com");
    logger.flush();

    const date = currentDateBuf();
    var buf: [4096]u8 = undefined;
    const n = readLogFile(save_path, &date, "log", &buf);

    try std.testing.expect(n > 0);
    const content = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, content, "GET") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "/api/users") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "200") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "512") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "INFO ") != null);
}

test "zix integration: access() absent UA and origin logged as dash" {
    const allocator = std.testing.allocator;
    const save_path = ".zig-cache/tmp/zix-logger-test/access-dash";
    ensureDirAll(save_path);

    var logger = try zix.Logger.init(allocator, .{
        .save_path = save_path,
        .save_file = "log",
        .save_min_level = .DEBUG,
    });
    defer logger.deinit();

    logger.access("POST", "/submit", 200, 0, "", "");
    logger.flush();

    const date = currentDateBuf();
    var buf: [4096]u8 = undefined;
    const n = readLogFile(save_path, &date, "log", &buf);

    try std.testing.expect(n > 0);
    const content = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, content, "\"-\"") != null);
}

test "zix integration: access() present UA appears in file" {
    const allocator = std.testing.allocator;
    const save_path = ".zig-cache/tmp/zix-logger-test/access-ua";
    ensureDirAll(save_path);

    var logger = try zix.Logger.init(allocator, .{
        .save_path = save_path,
        .save_file = "log",
        .save_min_level = .DEBUG,
    });
    defer logger.deinit();

    logger.access("GET", "/", 200, 0, "MyBot/2.0", "");
    logger.flush();

    const date = currentDateBuf();
    var buf: [4096]u8 = undefined;
    const n = readLogFile(save_path, &date, "log", &buf);

    try std.testing.expect(n > 0);
    const content = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, content, "MyBot/2.0") != null);
}

test "zix integration: system() 5xx status maps to ERROR level" {
    const allocator = std.testing.allocator;
    const save_path = ".zig-cache/tmp/zix-logger-test/access-error";
    ensureDirAll(save_path);

    var logger = try zix.Logger.init(allocator, .{
        .save_path = save_path,
        .save_file = "log",
        .save_min_level = .DEBUG,
    });
    defer logger.deinit();

    logger.access("GET", "/crash", 500, 0, "", "");
    logger.flush();

    const date = currentDateBuf();
    var buf: [4096]u8 = undefined;
    const n = readLogFile(save_path, &date, "log", &buf);

    try std.testing.expect(n > 0);
    const content = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, content, "ERROR") != null);
}

test "zix integration: system() with anyerror arg formats correctly" {
    const allocator = std.testing.allocator;
    const save_path = ".zig-cache/tmp/zix-logger-test/system-err";
    ensureDirAll(save_path);

    var logger = try zix.Logger.init(allocator, .{
        .save_path = save_path,
        .save_file = "log",
        .save_min_level = .DEBUG,
    });
    defer logger.deinit();

    const err: anyerror = error.OutOfMemory;
    logger.system(.ERROR, "db", "query failed: {}", .{err});
    logger.flush();

    const date = currentDateBuf();
    var buf: [4096]u8 = undefined;
    const n = readLogFile(save_path, &date, "log", &buf);

    try std.testing.expect(n > 0);
    const content = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, content, "[db]") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "OutOfMemory") != null);
}
