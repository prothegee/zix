//! ZIX utils static variant
//!
//! ### file: src/zix/utils/static/StaticVariant.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! One servable form of a cached static file (identity, gzip, or br): the open
//! file, its size, its 200 header, and optional resident bytes.
//!
//! ### note:
//!
//! Zeroed memory is a valid empty variant (present false, mapped false), since
//! the slot table is a zeroed mapping.
//! The resident bytes are a snapshot copy, not a file mapping. A file rewritten
//! in place would change under a mapping that a response is still reading.
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
const slab_mem = @import("../../multiplexers/slab.zig");
const content = @import("../http/content.zig");
const Encoding = @import("../http/encoding.zig").Encoding;
const file_utils = @import("../file.zig");
const cache_header = @import("cache_header.zig");

// --------------------------------------------------------- //
// Fields:

/// Open file, valid only while present is true.
file: std.Io.File,
/// File size in bytes.
size: u64,
/// MIME type, from the identity name.
content_type: []const u8,
/// Used length of hdr_buf.
hdr_len: u16,
/// Prerendered 200 header.
hdr_buf: [cache_header.HEADER_MAX]u8,
/// Whether the file is open.
present: bool,
/// Start of the resident snapshot, valid once mapped reads true.
map_ptr: [*]const u8 = undefined,
/// Length of the resident snapshot.
map_len: usize = 0,
/// Published last with release ordering, so a reader that sees true also sees
/// map_ptr and map_len.
mapped: std.atomic.Value(bool) = .init(false),

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// Largest file the cache snapshots into memory. A larger file is still served
/// from its descriptor.
pub const SNAPSHOT_MAX_BYTES: u64 = 8 * 1024 * 1024;

/// The prerendered 200 header.
///
/// Return:
/// - []const u8
pub fn header(self: *const Self) []const u8 {
    return self.hdr_buf[0..self.hdr_len];
}

/// The resident snapshot.
///
/// Note:
/// - Valid only after map returned true.
///
/// Return:
/// - []const u8
pub fn bytes(self: *const Self) []const u8 {
    return self.map_ptr[0..self.map_len];
}

/// Open one file and render the header it replays.
///
/// Param:
/// io - std.Io (open, stat, close)
/// path - []const u8 (file actually opened, sibling suffix included)
/// type_path - []const u8 (path the MIME type comes from, the identity name)
/// encoding - Encoding (the coding this file holds)
///
/// Return:
/// - bool (true when the variant is open and usable)
pub fn open(
    self: *Self,
    io: std.Io,
    path: []const u8,
    type_path: []const u8,
    encoding: Encoding,
) bool {
    self.present = false;

    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        else => return false,
    };

    const stat = file.stat(io) catch |err| switch (err) {
        else => {
            file.close(io);

            return false;
        },
    };

    if (stat.kind != .file) {
        file.close(io);

        return false;
    }

    const content_type = content.fromExtension(file_utils.extension(type_path));
    const rendered = cache_header.render(&self.hdr_buf, content_type, stat.size, encoding);
    const header_bytes = rendered orelse {
        file.close(io);

        return false;
    };

    self.file = file;
    self.size = stat.size;
    self.content_type = content_type;
    self.hdr_len = @intCast(header_bytes.len);
    self.present = true;

    return true;
}

/// Read the whole file once into a demand-paged snapshot.
///
/// Note:
/// - The caller holds the cache lock.
/// - An empty file needs no snapshot.
/// - A file past SNAPSHOT_MAX_BYTES is refused.
///
/// Param:
/// io - std.Io (positional read)
///
/// Return:
/// - bool (true when bytes() is valid)
pub fn map(self: *Self, io: std.Io) bool {
    if (self.mapped.load(.acquire)) return true;
    if (!self.present) return false;

    if (self.size == 0) {
        self.map_ptr = "";
        self.map_len = 0;
        self.mapped.store(true, .release);

        return true;
    }

    if (self.size > SNAPSHOT_MAX_BYTES) return false;

    const size: usize = std.math.cast(usize, self.size) orelse return false;
    const buf = slab_mem.mapZeroedSlots(u8, size) catch |err| switch (err) {
        error.ZixUtils_Slab_OutOfMemory,
        error.ZixUtils_Slab_MapFailed,
        => return false,
    };

    const read = self.file.readPositionalAll(io, buf, 0) catch |err| switch (err) {
        else => {
            slab_mem.unmapSlots(buf);

            return false;
        },
    };

    if (read != size) {
        slab_mem.unmapSlots(buf);

        return false;
    }

    self.map_ptr = buf.ptr;
    self.map_len = buf.len;
    self.mapped.store(true, .release);

    return true;
}

/// Drop the snapshot and close the file.
///
/// Note:
/// - The caller holds the cache lock and the slot is no longer live.
///
/// Param:
/// io - std.Io (close)
pub fn close(self: *Self, io: std.Io) void {
    if (self.mapped.load(.acquire)) {
        if (self.map_len > 0) slab_mem.unmapSlots(@constCast(self.bytes()));

        self.mapped.store(false, .release);
        self.map_len = 0;
    }

    if (!self.present) return;

    self.file.close(io);
    self.present = false;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// Write one fixture and return the joined path to it.
fn fixture(
    tmp: *std.testing.TmpDir,
    buf: []u8,
    name: []const u8,
    data: []const u8,
) []const u8 {
    tmp.dir.writeFile(std.testing.io, .{
        .sub_path = name,
        .data = data,
    }) catch |err| switch (err) {
        else => @panic("fixture write failed"),
    };

    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}/{s}", .{
        tmp.sub_path,
        name,
    }) catch |err| switch (err) {
        error.NoSpaceLeft => @panic("fixture path too long"),
    };
}

fn emptyVariant() Self {
    var variant: Self = undefined;
    variant.present = false;
    variant.map_len = 0;
    variant.mapped = .init(false);

    return variant;
}

test "zix utils static: StaticVariant, open reads size and type" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    const path = fixture(&tmp, &path_buf, "a.css", "body{}");

    var variant = emptyVariant();
    defer variant.close(std.testing.io);

    try std.testing.expect(variant.open(std.testing.io, path, path, .IDENTITY));
    try std.testing.expectEqual(@as(u64, 6), variant.size);
    try std.testing.expectEqualStrings("text/css", variant.content_type);
}

test "zix utils static: StaticVariant, open renders the header" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    const path = fixture(&tmp, &path_buf, "a.txt", "hello");

    var variant = emptyVariant();
    defer variant.close(std.testing.io);

    try std.testing.expect(variant.open(std.testing.io, path, path, .IDENTITY));
    const length_line = "Content-Length: 5\r\n";

    try std.testing.expect(std.mem.indexOf(u8, variant.header(), length_line) != null);
}

test "zix utils static: StaticVariant, open takes the type from type_path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    const path = fixture(&tmp, &path_buf, "app.js.br", "xx");

    var variant = emptyVariant();
    defer variant.close(std.testing.io);

    try std.testing.expect(variant.open(std.testing.io, path, "app.js", .BR));
    try std.testing.expectEqualStrings("application/javascript", variant.content_type);
}

test "zix utils static: StaticVariant, open missing file is false" {
    var variant = emptyVariant();

    try std.testing.expect(!variant.open(std.testing.io, "no/such/file", "file", .IDENTITY));
    try std.testing.expect(!variant.present);
}

test "zix utils static: StaticVariant, open directory is false" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var variant = emptyVariant();

    try std.testing.expect(!variant.open(std.testing.io, path, path, .IDENTITY));
}

test "zix utils static: StaticVariant, map snapshots the bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    const path = fixture(&tmp, &path_buf, "m.txt", "snapshot");

    var variant = emptyVariant();
    defer variant.close(std.testing.io);

    try std.testing.expect(variant.open(std.testing.io, path, path, .IDENTITY));
    try std.testing.expect(variant.map(std.testing.io));
    try std.testing.expectEqualStrings("snapshot", variant.bytes());
}

test "zix utils static: StaticVariant, map empty file is an empty slice" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    const path = fixture(&tmp, &path_buf, "empty.txt", "");

    var variant = emptyVariant();
    defer variant.close(std.testing.io);

    try std.testing.expect(variant.open(std.testing.io, path, path, .IDENTITY));
    try std.testing.expect(variant.map(std.testing.io));
    try std.testing.expectEqual(@as(usize, 0), variant.bytes().len);
}

test "zix utils static: StaticVariant, map without a file is false" {
    var variant = emptyVariant();

    try std.testing.expect(!variant.map(std.testing.io));
}

test "zix utils static: StaticVariant, map past SNAPSHOT_MAX_BYTES is false" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    const path = fixture(&tmp, &path_buf, "big.txt", "x");

    var variant = emptyVariant();
    defer variant.close(std.testing.io);

    try std.testing.expect(variant.open(std.testing.io, path, path, .IDENTITY));
    variant.size = SNAPSHOT_MAX_BYTES + 1;

    try std.testing.expect(!variant.map(std.testing.io));
}

test "zix utils static: StaticVariant, close clears present" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    const path = fixture(&tmp, &path_buf, "c.txt", "close");

    var variant = emptyVariant();

    try std.testing.expect(variant.open(std.testing.io, path, path, .IDENTITY));
    try std.testing.expect(variant.map(std.testing.io));

    variant.close(std.testing.io);

    try std.testing.expect(!variant.present);
    try std.testing.expect(!variant.mapped.load(.acquire));
}

