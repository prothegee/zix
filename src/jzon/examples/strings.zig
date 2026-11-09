//! JZON example strings
//!
//! ### file: src/jzon/examples/strings.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Where a parsed string's bytes live: `.COPY` against `.BORROW`, in JSON and ZON.
//!
//! ### note:
//!
//! `.COPY` copies every string into the allocator, so the value outlives the
//! document. `.BORROW` points a string with no escape at the document, which costs
//! no copy and makes the document part of the value's lifetime. A string with an
//! escape is copied under both, because its decoded bytes are not in the document.
//! Build with `zig build example-strings` from `src/jzon`, then run
//! `./zig-out/bin/jzon-example-strings-<arch>-<os>-<mode>`.
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
const jzon = @import("jzon");

// --------------------------------------------------------- //
// Private:

/// Every read path, so both modes can be shown on all of them.
const STRATEGIES = [_]jzon.json.DeserializeStrategy{
    .STD,
    .SCANNER,
    .GENERATED,
    .GENERATED_VECTOR,
};

const Note = struct {
    plain: []const u8,
    escaped: []const u8,
};

/// `plain` has no escape in it, `escaped` carries a tab written as `\t`.
const JSON_DOCUMENT = "{\"plain\":\"leave at the door\",\"escaped\":\"one\\ttwo\"}";

/// The same note as ZON.
const ZON_DOCUMENT = ".{ .plain = \"leave at the door\", .escaped = \"one\\ttwo\" }";

/// Whether `text` sits inside `document` rather than in memory of its own.
fn pointsIntoDocument(text: []const u8, document: []const u8) bool {
    const document_start = @intFromPtr(document.ptr);
    const text_start = @intFromPtr(text.ptr);

    return text_start >= document_start and text_start < document_start + document.len;
}

/// Print where each string of a note ended up.
fn report(label: []const u8, note: Note, document: []const u8) void {
    std.debug.print("{s}:\n", .{label});
    std.debug.print("  plain   \"{s}\", in the document: {}\n", .{
        note.plain,
        pointsIntoDocument(note.plain, document),
    });
    std.debug.print("  escaped \"{s}\", in the document: {}\n", .{
        note.escaped,
        pointsIntoDocument(note.escaped, document),
    });
}

/// Read both documents in one mode.
fn readInMode(allocator: std.mem.Allocator, comptime mode: jzon.json.Strings) !void {
    const from_json = try jzon.json.deserialize(Note, allocator, JSON_DOCUMENT, .{
        .strings = mode,
    });
    const from_zon = try jzon.zon.deserialize(Note, allocator, ZON_DOCUMENT, .{
        .strings = mode,
    });

    report("json " ++ @tagName(mode), from_json, JSON_DOCUMENT);
    report("zon " ++ @tagName(mode), from_zon, ZON_DOCUMENT);
}

/// Show that the mode holds whichever JSON read path runs.
fn readEveryStrategyInBothModes(arena: *std.heap.ArenaAllocator) !void {
    inline for (STRATEGIES) |strategy| {
        defer _ = arena.reset(.retain_capacity);

        const copied = try jzon.json.deserialize(Note, arena.allocator(), JSON_DOCUMENT, .{
            .strategy = strategy,
            .strings = .COPY,
        });
        const borrowed = try jzon.json.deserialize(Note, arena.allocator(), JSON_DOCUMENT, .{
            .strategy = strategy,
            .strings = .BORROW,
        });

        std.debug.print("{t}: copied plain in the document: {}, borrowed: {}\n", .{
            strategy,
            pointsIntoDocument(copied.plain, JSON_DOCUMENT),
            pointsIntoDocument(borrowed.plain, JSON_DOCUMENT),
        });
    }

    std.debug.print("\n", .{});
}

/// What a borrowed string is worth only while its document is alive.
fn showTheLifetimeRule(allocator: std.mem.Allocator) !void {
    // The document is built here rather than being a literal, so it is the kind of
    // buffer a server reuses: read into it, parse out of it, read the next request.
    var body: [64]u8 = undefined;
    const format = "{{\"plain\":\"{s}\",\"escaped\":\"a\\tb\"}}";
    const src = try std.fmt.bufPrint(&body, format, .{"first"});

    const note = try jzon.json.deserialize(Note, allocator, src, .{ .strings = .BORROW });

    std.debug.print("borrowed before the buffer is reused: \"{s}\"\n", .{note.plain});

    // Reusing the buffer rewrites what the borrowed string points at. Nothing here
    // is unsafe, the bytes are simply not the ones that were parsed.
    _ = try std.fmt.bufPrint(&body, format, .{"later"});

    std.debug.print("borrowed after the buffer is reused:  \"{s}\"\n", .{note.plain});
    std.debug.print("the escaped string was copied, so it is untouched: \"{s}\"\n", .{
        note.escaped,
    });
}

// --------------------------------------------------------- //
// Public:

// main takes no std.process.Init because a parse touches no IO. It only needs an
// allocator.
pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();

    try readInMode(arena.allocator(), .COPY);
    try readInMode(arena.allocator(), .BORROW);
    std.debug.print("\n", .{});

    _ = arena.reset(.retain_capacity);

    try readEveryStrategyInBothModes(&arena);
    try showTheLifetimeRule(arena.allocator());
}

