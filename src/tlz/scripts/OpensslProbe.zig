//! TLZ scripts OpensslProbe
//!
//! ### file: src/tlz/scripts/OpensslProbe.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Find OpenSSL on the build host and read its version, the same way on every OS.
//! Used by `build.zig` (configure time) and `openssl_check.zig` (the check step).
//!
//! ### note:
//!
//! Probe order: the `OPENSSL_DIR` env var, then `pkg-config`, then the standard include
//! directories (never on a Windows host). No `std.Build` here, so the check program
//! can run the same probe. Every returned slice lives in the caller allocator.
//!
//! ---------------------------------------------------------
//!
//! ### licenses:
//!
//! - BSD-3-Clause
//!
//! ### copyright:
//!
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//!
//! ### contributors:
//!
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");

// --------------------------------------------------------- //
// Fields:

/// Where OpenSSL was found.
source: Source,
/// The OpenSSL version, null when it could not be read.
version: ?std.SemanticVersion,
/// The directory that holds `openssl/ssl.h`, null when unknown.
include_dir: ?[]const u8,
/// The directory that holds libssl and libcrypto, set only from `OPENSSL_DIR`.
lib_dir: ?[]const u8,

const Self = @This();

// --------------------------------------------------------- //
// Private:

/// The env var that names an OpenSSL install: `<dir>/include` and `<dir>/lib`.
const ENV_NAME = "OPENSSL_DIR";

/// Include directories checked last, on a host that is not Windows.
const STANDARD_INCLUDE_DIRS = [_][]const u8{
    "/usr/include",
    "/usr/local/include",
};

/// The version line in `opensslv.h` (OpenSSL 3.0 and newer), up to the opening quote.
const VERSION_STR_PREFIX = "OPENSSL_VERSION_STR \"";

/// The largest `opensslv.h` read. The real file is a few KiB.
const VERSION_HEADER_LIMIT: usize = 64 * 1024;

/// The largest `pkg-config` output read.
const PKG_CONFIG_OUTPUT_LIMIT: usize = 4 * 1024;

/// Join path parts with the separator of the host.
fn joinPath(allocator: std.mem.Allocator, parts: []const []const u8) Error![]const u8 {
    return std.fs.path.join(allocator, parts) catch |err| switch (err) {
        error.OutOfMemory => Error.Tlz_OpensslProbe_OutOfMemory,
    };
}

/// True when `path` (absolute, or relative to the working directory) is readable.
fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{
        .read = true,
    }) catch |err| switch (err) {
        // Best effort probe: any failure means the file does not count.
        else => return false,
    };

    return true;
}

/// True when `include_dir/openssl/ssl.h` is readable.
fn hasSslHeader(allocator: std.mem.Allocator, io: std.Io, include_dir: []const u8) Error!bool {
    const path = try joinPath(allocator, &.{
        include_dir,
        "openssl",
        "ssl.h",
    });

    return fileExists(io, path);
}

/// Run `pkg-config <flag> openssl` and return its trimmed output.
///
/// Return:
/// - []const u8 (the output, may be empty)
/// - null when `pkg-config` is missing, fails, or exits non zero
fn pkgConfig(allocator: std.mem.Allocator, io: std.Io, flag: []const u8) ?[]const u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{
            "pkg-config",
            flag,
            "openssl",
        },
        .stdout_limit = .limited(PKG_CONFIG_OUTPUT_LIMIT),
        .stderr_limit = .limited(PKG_CONFIG_OUTPUT_LIMIT),
    }) catch |err| switch (err) {
        // Best effort probe: a missing or broken pkg-config means no answer.
        else => return null,
    };

    if (!result.term.success()) return null;

    return std.mem.trim(u8, result.stdout, " \t\r\n");
}

/// Read `OPENSSL_VERSION_STR` from `include_dir/openssl/opensslv.h`.
///
/// Return:
/// - std.SemanticVersion
/// - null when the header is not readable or has no version line
fn headerVersion(
    allocator: std.mem.Allocator,
    io: std.Io,
    include_dir: []const u8,
) Error!?std.SemanticVersion {
    const path = try joinPath(allocator, &.{
        include_dir,
        "openssl",
        "opensslv.h",
    });
    const text = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(VERSION_HEADER_LIMIT),
    ) catch |err| switch (err) {
        error.OutOfMemory => return Error.Tlz_OpensslProbe_OutOfMemory,
        // Best effort probe: any other failure means no version from this header.
        else => return null,
    };

    const start = std.mem.find(u8, text, VERSION_STR_PREFIX) orelse return null;
    const rest = text[start + VERSION_STR_PREFIX.len ..];
    const end = std.mem.findScalar(u8, rest, '"') orelse return null;

    return parseVersion(rest[0..end]);
}

/// OpenSSL from the `OPENSSL_DIR` env var.
fn probeEnv(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) Error!Self {
    const include_dir = try joinPath(allocator, &.{
        dir,
        "include",
    });
    const has_header = try hasSslHeader(allocator, io, include_dir);
    if (!has_header) return Error.Tlz_OpensslProbe_EnvDirInvalid;

    return .{
        .source = .ENV,
        .version = try headerVersion(allocator, io, include_dir),
        .include_dir = include_dir,
        .lib_dir = try joinPath(allocator, &.{
            dir,
            "lib",
        }),
    };
}

/// OpenSSL from `pkg-config`, null when `pkg-config` does not know it.
fn probePkgConfig(allocator: std.mem.Allocator, io: std.Io) Error!?Self {
    const version_text = pkgConfig(allocator, io, "--modversion") orelse return null;
    const include_text = pkgConfig(allocator, io, "--variable=includedir") orelse "";
    const include_dir: ?[]const u8 = if (include_text.len == 0) null else include_text;

    const header_version: ?std.SemanticVersion = if (include_dir) |dir|
        try headerVersion(allocator, io, dir)
    else
        null;

    return .{
        .source = .PKG_CONFIG,
        .version = parseVersion(version_text) orelse header_version,
        .include_dir = include_dir,
        .lib_dir = null,
    };
}

/// OpenSSL from the standard include directories, null when none has it.
fn probeStandard(
    allocator: std.mem.Allocator,
    io: std.Io,
    host_os: std.Target.Os.Tag,
) Error!?Self {
    for (standardIncludeDirs(host_os)) |dir| {
        if (!try hasSslHeader(allocator, io, dir)) continue;

        return .{
            .source = .STANDARD_PATH,
            .version = try headerVersion(allocator, io, dir),
            .include_dir = dir,
            .lib_dir = null,
        };
    }

    return null;
}

// --------------------------------------------------------- //
// Public:

pub const Error = error{
    Tlz_OpensslProbe_EnvDirInvalid,
    Tlz_OpensslProbe_OutOfMemory,
};

/// Where the probe found OpenSSL.
pub const Source = enum(u8) {
    NONE,
    ENV,
    PKG_CONFIG,
    STANDARD_PATH,
};

/// The oldest supported OpenSSL: 3.5 on the 3.x line. Every 4.x (floor 4.0) is above it.
pub const OPENSSL_FLOOR: std.SemanticVersion = .{
    .major = 3,
    .minor = 5,
    .patch = 0,
};

/// The probe result when OpenSSL is not found.
pub const NOT_FOUND: Self = .{
    .source = .NONE,
    .version = null,
    .include_dir = null,
    .lib_dir = null,
};

/// Find OpenSSL on the build host.
///
/// Note:
/// - An `OPENSSL_DIR` without `include/openssl/ssl.h` is an error, never a silent
///   fall back to `pkg-config`.
///
/// Param:
/// allocator - std.mem.Allocator (an arena: the returned slices live in it)
/// io - std.Io (runs `pkg-config` and reads the headers)
/// environ_map - *const std.process.Environ.Map (the env, read for `OPENSSL_DIR`)
/// host_os - std.Target.Os.Tag (the build host OS, Windows skips the standard paths)
///
/// Return:
/// - Self (`NOT_FOUND` when no probe finds OpenSSL)
/// - Error.Tlz_OpensslProbe_EnvDirInvalid when `OPENSSL_DIR` has no OpenSSL headers
/// - Error.Tlz_OpensslProbe_OutOfMemory when a path does not fit in memory
pub fn probe(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    host_os: std.Target.Os.Tag,
) Error!Self {
    if (environ_map.get(ENV_NAME)) |dir| {
        if (dir.len > 0) return probeEnv(allocator, io, dir);
    }

    if (try probePkgConfig(allocator, io)) |found_by_pkg_config| return found_by_pkg_config;
    if (try probeStandard(allocator, io, host_os)) |found_by_path| return found_by_path;

    return NOT_FOUND;
}

/// Parse "major.minor.patch" (patch optional). Text after the numbers is ignored,
/// so "1.1.1w" reads as 1.1.1.
///
/// Param:
/// text - []const u8 (the version text)
///
/// Return:
/// - std.SemanticVersion
/// - null when major or minor is missing or not a number
pub fn parseVersion(text: []const u8) ?std.SemanticVersion {
    var numbers: [3]usize = @splat(0);
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, text, '.');

    while (parts.next()) |part| {
        if (count == numbers.len) break;

        const digits_len = std.mem.findNone(u8, part, "0123456789") orelse part.len;
        if (digits_len == 0) break;

        numbers[count] = std.fmt.parseInt(usize, part[0..digits_len], 10) catch |err| {
            switch (err) {
                error.Overflow, error.InvalidCharacter => return null,
            }
        };
        count += 1;

        if (digits_len != part.len) break;
    }

    if (count < 2) return null;

    return .{
        .major = numbers[0],
        .minor = numbers[1],
        .patch = numbers[2],
    };
}

/// The include directories the probe checks last.
///
/// Param:
/// host_os - std.Target.Os.Tag (the build host OS)
///
/// Return:
/// - []const []const u8 (empty on Windows)
pub fn standardIncludeDirs(host_os: std.Target.Os.Tag) []const []const u8 {
    if (host_os == .windows) return &.{};

    return &STANDARD_INCLUDE_DIRS;
}

/// OpenSSL was found.
pub fn found(self: *const Self) bool {
    return self.source != .NONE;
}

/// The version is known and below `OPENSSL_FLOOR`.
pub fn belowFloor(self: *const Self) bool {
    const version = self.version orelse return false;

    return version.order(OPENSSL_FLOOR) == .lt;
}

/// The OpenSSL call that checks the server name on this line
/// (see `src/openssl/client.zig`).
///
/// Return:
/// - "SSL_set1_dnsname" for 4.x and newer
/// - "SSL_set1_host" for 3.x or an unknown version
pub fn hostCheckCall(self: *const Self) []const u8 {
    const version = self.version orelse return "SSL_set1_host";
    if (version.major >= 4) return "SSL_set1_dnsname";

    return "SSL_set1_host";
}

/// The `opensslv.h` path to watch for a change.
///
/// Return:
/// - []const u8 (inside `allocator`)
/// - null when the include directory is unknown
/// - Error.Tlz_OpensslProbe_OutOfMemory
pub fn versionHeaderPath(self: *const Self, allocator: std.mem.Allocator) Error!?[]const u8 {
    const include_dir = self.include_dir orelse return null;

    return try joinPath(allocator, &.{
        include_dir,
        "openssl",
        "opensslv.h",
    });
}

/// A short state text for logs and for the check step: "none", "unknown", or the version.
///
/// Param:
/// buf - []u8 (the output, 32 bytes hold any version)
///
/// Return:
/// - []const u8 (inside `buf`, "none" when `buf` is too small for the version)
pub fn stateText(self: *const Self, buf: []u8) []const u8 {
    if (!self.found()) return "none";

    const version = self.version orelse return "unknown";

    return std.fmt.bufPrint(buf, "{d}.{d}.{d}", .{
        version.major,
        version.minor,
        version.patch,
    }) catch |err| switch (err) {
        error.NoSpaceLeft => "none",
    };
}

/// The name of `source` for logs.
pub fn sourceName(self: *const Self) []const u8 {
    return switch (self.source) {
        .NONE => "none",
        .ENV => ENV_NAME,
        .PKG_CONFIG => "pkg-config",
        .STANDARD_PATH => "standard include path",
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// A fake OpenSSL install in `tmp`: include/openssl/ssl.h and opensslv.h.
fn writeFakeInstall(tmp: *std.testing.TmpDir, version_line: []const u8) !void {
    const io = std.testing.io;

    try tmp.dir.createDirPath(io, "include/openssl");
    try tmp.dir.writeFile(io, .{
        .sub_path = "include/openssl/ssl.h",
        .data = "/* fake */\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "include/openssl/opensslv.h",
        .data = version_line,
    });
}

/// The fake install path, relative to the working directory.
fn tmpRoot(buf: []u8, tmp: *const std.testing.TmpDir) ![]const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

/// Probe with only `OPENSSL_DIR` set in the env.
fn probeWithEnvDir(arena: std.mem.Allocator, dir: []const u8) Error!Self {
    var environ_map: std.process.Environ.Map = .init(arena);
    environ_map.put(ENV_NAME, dir) catch |err| switch (err) {
        error.OutOfMemory => return Error.Tlz_OpensslProbe_OutOfMemory,
    };

    return probe(arena, std.testing.io, &environ_map, .linux);
}

test "tlz scripts: OpensslProbe, parseVersion reads major minor patch" {
    const version = parseVersion("4.1.0").?;

    try std.testing.expectEqual(@as(usize, 4), version.major);
    try std.testing.expectEqual(@as(usize, 1), version.minor);
    try std.testing.expectEqual(@as(usize, 0), version.patch);
}

test "tlz scripts: OpensslProbe, parseVersion without a patch reads patch 0" {
    const version = parseVersion("3.5").?;

    try std.testing.expectEqual(@as(usize, 3), version.major);
    try std.testing.expectEqual(@as(usize, 5), version.minor);
    try std.testing.expectEqual(@as(usize, 0), version.patch);
}

test "tlz scripts: OpensslProbe, parseVersion ignores a letter suffix" {
    const version = parseVersion("1.1.1w").?;

    try std.testing.expectEqual(@as(usize, 1), version.patch);
}

test "tlz scripts: OpensslProbe, parseVersion of a major alone is null" {
    try std.testing.expect(parseVersion("3") == null);
}

test "tlz scripts: OpensslProbe, parseVersion of empty text is null" {
    try std.testing.expect(parseVersion("") == null);
}

test "tlz scripts: OpensslProbe, parseVersion of text is null" {
    try std.testing.expect(parseVersion("abc") == null);
}

test "tlz scripts: OpensslProbe, parseVersion past usize is null" {
    try std.testing.expect(parseVersion("99999999999999999999999.1") == null);
}

test "tlz scripts: OpensslProbe, standardIncludeDirs on Windows is empty" {
    try std.testing.expectEqual(@as(usize, 0), standardIncludeDirs(.windows).len);
}

test "tlz scripts: OpensslProbe, standardIncludeDirs on Linux has usr include" {
    try std.testing.expectEqualStrings("/usr/include", standardIncludeDirs(.linux)[0]);
}

test "tlz scripts: OpensslProbe, belowFloor 3.4 is true" {
    var result = NOT_FOUND;
    result.source = .PKG_CONFIG;
    result.version = parseVersion("3.4.9");

    try std.testing.expect(result.belowFloor());
}

test "tlz scripts: OpensslProbe, belowFloor at 3.5.0 is false" {
    var result = NOT_FOUND;
    result.source = .PKG_CONFIG;
    result.version = parseVersion("3.5.0");

    try std.testing.expect(!result.belowFloor());
}

test "tlz scripts: OpensslProbe, belowFloor 4.0 is false" {
    var result = NOT_FOUND;
    result.source = .PKG_CONFIG;
    result.version = parseVersion("4.0.0");

    try std.testing.expect(!result.belowFloor());
}

test "tlz scripts: OpensslProbe, belowFloor of an unknown version is false" {
    var result = NOT_FOUND;
    result.source = .STANDARD_PATH;

    try std.testing.expect(!result.belowFloor());
}

test "tlz scripts: OpensslProbe, hostCheckCall on 4.x is SSL_set1_dnsname" {
    var result = NOT_FOUND;
    result.version = parseVersion("4.0.0");

    try std.testing.expectEqualStrings("SSL_set1_dnsname", result.hostCheckCall());
}

test "tlz scripts: OpensslProbe, hostCheckCall on 3.x is SSL_set1_host" {
    var result = NOT_FOUND;
    result.version = parseVersion("3.5.4");

    try std.testing.expectEqualStrings("SSL_set1_host", result.hostCheckCall());
}

test "tlz scripts: OpensslProbe, stateText not found is none" {
    var buf: [32]u8 = undefined;

    try std.testing.expectEqualStrings("none", NOT_FOUND.stateText(&buf));
}

test "tlz scripts: OpensslProbe, stateText without a version is unknown" {
    var result = NOT_FOUND;
    result.source = .STANDARD_PATH;
    var buf: [32]u8 = undefined;

    try std.testing.expectEqualStrings("unknown", result.stateText(&buf));
}

test "tlz scripts: OpensslProbe, stateText prints the version" {
    var result = NOT_FOUND;
    result.source = .PKG_CONFIG;
    result.version = parseVersion("3.5.2");
    var buf: [32]u8 = undefined;

    try std.testing.expectEqualStrings("3.5.2", result.stateText(&buf));
}

test "tlz scripts: OpensslProbe, stateText with a small buffer is none" {
    var result = NOT_FOUND;
    result.source = .PKG_CONFIG;
    result.version = parseVersion("3.5.2");
    var buf: [2]u8 = undefined;

    try std.testing.expectEqualStrings("none", result.stateText(&buf));
}

test "tlz scripts: OpensslProbe, versionHeaderPath without an include dir is null" {
    try std.testing.expect(try NOT_FOUND.versionHeaderPath(std.testing.allocator) == null);
}

test "tlz scripts: OpensslProbe, OPENSSL_DIR reads the version from opensslv.h" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFakeInstall(&tmp, "# define OPENSSL_VERSION_STR \"3.5.2\"\n");
    var root_buf: [128]u8 = undefined;

    const result = try probeWithEnvDir(arena_state.allocator(), try tmpRoot(&root_buf, &tmp));

    try std.testing.expectEqual(Source.ENV, result.source);
    try std.testing.expectEqual(@as(usize, 5), result.version.?.minor);
    try std.testing.expect(std.mem.endsWith(u8, result.lib_dir.?, "lib"));
}

test "tlz scripts: OpensslProbe, OPENSSL_DIR without a version line is unknown" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFakeInstall(&tmp, "/* no version */\n");
    var root_buf: [128]u8 = undefined;

    const result = try probeWithEnvDir(arena_state.allocator(), try tmpRoot(&root_buf, &tmp));

    try std.testing.expectEqual(Source.ENV, result.source);
    try std.testing.expect(result.version == null);
}

test "tlz scripts: OpensslProbe, OPENSSL_DIR without headers is EnvDirInvalid" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [128]u8 = undefined;

    try std.testing.expectError(
        Error.Tlz_OpensslProbe_EnvDirInvalid,
        probeWithEnvDir(arena_state.allocator(), try tmpRoot(&root_buf, &tmp)),
    );
}

test "tlz scripts: OpensslProbe, versionHeaderPath ends with opensslv.h" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFakeInstall(&tmp, "# define OPENSSL_VERSION_STR \"4.0.1\"\n");
    var root_buf: [128]u8 = undefined;
    const arena = arena_state.allocator();

    const result = try probeWithEnvDir(arena, try tmpRoot(&root_buf, &tmp));
    const path = (try result.versionHeaderPath(arena)).?;

    try std.testing.expect(std.mem.endsWith(u8, path, "opensslv.h"));
}

