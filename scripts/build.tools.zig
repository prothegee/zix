//! ZIX script build tools
//!
//! ### file: scripts/build.tools.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! Build helpers: Zig version gate, required paths, and version info.
//! 
//! ### note:
//! n/a
//! 
//! ---------------------------------------------------------
//! 
//! ### licenses:
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
const builtin = @import("builtin");

// --------------------------------------------------------- //

const ALLOWED_ZIG = struct {
    pub const MAJOR: usize = 0;
    pub const MINOR: usize = 17;
    pub const PATCH: usize = 0;
};

const REQUIRED_DIRS = [_][]const u8{
    "src",
    "tests",
};

const REQUIRED_FILES = [_][]const u8{
    "src/zix/lib.zig",
    "src/zix/test.zig",
};

pub const VersionInfo = struct {
    major: usize,
    minor: usize,
    patch: usize,
    release_candidate: ?usize,
};

/// THE ONLY SOURCE OF TRUTH for Zig SEMVER for zix build tools.
///
/// Note:
/// - Do not create in other place
pub const ZIG = struct {
    pub const MAJOR: usize = builtin.zig_version.major;
    pub const MINOR: usize = builtin.zig_version.minor;
    pub const PATCH: usize = builtin.zig_version.patch;
};

// --------------------------------------------------------- //

pub fn ensureSupportedZig() void {
    // MAJOR
    if (ZIG.MAJOR != ALLOWED_ZIG.MAJOR) {
        @compileError(std.fmt.comptimePrint(
            "Required Zig {d} for major version.\n" ++ 
            "Found {d}.",
            .{
                ALLOWED_ZIG.MAJOR,
                ZIG.MAJOR,
            },
        ));
    }

    // MINOR
    if (ZIG.MINOR != ALLOWED_ZIG.MINOR) {
        @compileError(std.fmt.comptimePrint(
            "Required Zig {d} for minor version.\n" ++ 
            "Found {d}.",
            .{
                ALLOWED_ZIG.MINOR,
                ZIG.MINOR,
            },
        ));
    }

    // PATCH: Skip for now

    // Finally
    std.log.info(
        "Using Zig toolchain: {d}.{d}.{d}\n",
        .{ ZIG.MAJOR, ZIG.MINOR, ZIG.PATCH },
    );
}

pub fn diExists(b: *std.Build, sub_path: []const u8) bool {
    const root_handle = b.root.root_dir.handle;

    root_handle.access(b.graph.io, sub_path, .{}) catch return false;

    return true;
}

pub fn fileExists(b: *std.Build, file_path: []const u8) bool {
    return !std.meta.isError(
        std.Io.Dir.cwd().access(b.graph.io, file_path, .{})
    );
}

pub fn checkRequiredDirs(b: *std.Build) !void {
    for (REQUIRED_DIRS) |dir| {
        if (!diExists(b, dir)) {
            var buf: [128]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "Error: '{s}' dir not exists\n", .{dir});
            std.log.err("{s}\n", .{msg});
        }
    }
}

pub fn checkRequiredFiles(b: *std.Build) !void {
    for (REQUIRED_FILES) |file| {
        if (!fileExists(b, file)) {
            var buf: [128]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "Error: '{s}' file not exists\n", .{file});
            std.log.err("{s}\n", .{msg});
        }
    }
}

