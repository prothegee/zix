//! JZON
//! JSON, in both directions.
//!
//! ### file: src/jzon/src/lib.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! JZON library entry: the version truth and the public exports.
//!
//! ### note:
//!
//! Tests run through `test.zig`, not through this file. Add a new source file there,
//! or its in-file tests never run.
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
const jzon_options = @import("jzon_options");

// --------------------------------------------------------- //
// Private:

fn getVersionString() []const u8 {
    return std.fmt.comptimePrint("{d}.{d}.{d}", .{
        VERSION.MAJOR,
        VERSION.MINOR,
        VERSION.PATCH,
    });
}

// --------------------------------------------------------- //
// Public:

/// THE ONLY SOURCE OF TRUTH for JZON SEMVER.
///
/// Note:
/// - The values come from `src/jzon/build.zig.zon` through the build options.
/// - Do not create in other place
pub const VERSION = struct {
    pub const MAJOR: usize = jzon_options.version_major;
    pub const MINOR: usize = jzon_options.version_minor;
    pub const PATCH: usize = jzon_options.version_patch;
};

/// THE ONLY SOURCE OF TRUTH for JZON string version, for example `0.1.0`.
///
/// Note:
/// - Do not create in other place
pub const VERSION_STRING = getVersionString();

/// Turn a typed value into JSON text, through the write path the options name.
pub const serialize = @import("serialize/serialize.zig").serialize;

/// Turn JSON text into a typed value, through the read path the options name.
pub const deserialize = @import("deserialize/deserialize.zig").deserialize;

/// What the last failed parse on this thread was about: the field, the byte, or both.
///
/// Note:
/// - Read it right after a parse returned an error, before another parse on the
///   same thread replaces it.
pub const lastFailure = Failure.lastFailure;

/// The options a render runs with.
pub const SerializeOptions = @import("serialize/SerializeOptions.zig");

/// Every way a render can fail.
pub const SerializeError = @import("serialize/serialize.zig").Error;

/// Which write path a render runs.
pub const SerializeStrategy = SerializeOptions.Strategy;

/// The options a parse runs with.
pub const DeserializeOptions = @import("deserialize/DeserializeOptions.zig");

/// Every way a parse can fail.
pub const DeserializeError = @import("deserialize/deserialize.zig").Error;

/// Which read path a parse runs.
pub const DeserializeStrategy = DeserializeOptions.Strategy;

/// Where a parsed string's bytes live.
pub const Strings = DeserializeOptions.Strings;

/// What happens to a key the target type does not declare.
pub const Unknown = DeserializeOptions.Unknown;

/// A bounds-checked write cursor over a caller-owned buffer.
pub const Sink = @import("Sink.zig");

/// A bounds-checked read cursor over a caller-owned document.
pub const Cursor = @import("Cursor.zig");

/// A located string token: the bytes between the quotes, plus whether they hold
/// an escape.
pub const StringSpan = @import("StringSpan.zig");

/// The vector lane width and the escape test on one chunk.
pub const lane = @import("lane.zig");

/// Read-cursor scans that classify a lane of bytes at once.
pub const cursor_vector = @import("cursor_vector.zig");

/// The JSON string escape rules, one byte at a time.
pub const escape = @import("escape.zig");

/// The JSON string escape rules, a lane of bytes at a time.
pub const escape_vector = @import("escape_vector.zig");

/// Integer digits in and out, through `std.fmt` or a digit table.
pub const integer = @import("integer.zig");

/// Float text in and out.
pub const float = @import("float.zig");

/// The questions a type is asked at comptime.
pub const reflect = @import("reflect.zig");

/// Which number and escape path a generated render takes.
pub const EmitShape = @import("serialize/EmitShape.zig");

/// Render a value the way std does, which takes every shape std takes.
pub const std_emitter = @import("serialize/std_emitter.zig");

/// Render a value through code generated from its type.
pub const generated_emitter = @import("serialize/generated_emitter.zig");

/// Which field and which byte the last failed parse on this thread was about.
pub const Failure = @import("deserialize/Failure.zig");

/// How many bytes a read scan classifies at once.
pub const ScanShape = @import("deserialize/ScanShape.zig");

/// Which of a target's fields a document filled in.
pub const fields = @import("deserialize/fields.zig");

/// Step over a whole value without building anything out of it.
pub const skip = @import("deserialize/skip.zig");

/// The value of one string token, borrowed or copied.
pub const string_value = @import("deserialize/string_value.zig");

/// Read a value the way std does, which parses every shape std parses.
pub const std_parser = @import("deserialize/std_parser.zig");

/// Read a value through std's tokens and dispatch generated from the type.
pub const scanner_parser = @import("deserialize/scanner_parser.zig");

/// Read a value through jzon's own cursor and code generated from the type.
pub const generated_parser = @import("deserialize/generated_parser.zig");

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "jzon: VERSION_STRING, matches the semver fields" {
    var buf: [64]u8 = undefined;
    const expected = try std.fmt.bufPrint(&buf, "{d}.{d}.{d}", .{
        VERSION.MAJOR,
        VERSION.MINOR,
        VERSION.PATCH,
    });

    try std.testing.expectEqualStrings(expected, VERSION_STRING);
}

test "jzon: VERSION_STRING, has exactly two dots" {
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, VERSION_STRING, "."));
}

test "jzon: VERSION_STRING, has no release candidate suffix" {
    try std.testing.expect(std.mem.findScalar(u8, VERSION_STRING, '-') == null);
}

test "jzon: VERSION, is not all zero" {
    const total = VERSION.MAJOR + VERSION.MINOR + VERSION.PATCH;

    try std.testing.expect(total > 0);
}

test "jzon: serialize, renders through the export" {
    var buf: [32]u8 = undefined;
    const len = try serialize(&buf, .{ .id = @as(u32, 7) }, .{});

    try std.testing.expectEqualStrings("{\"id\":7}", buf[0..len]);
}

test "jzon: deserialize, reads through the export" {
    const Target = struct { id: u32 };

    const value = try deserialize(Target, std.testing.allocator, "{\"id\":7}", .{});

    try std.testing.expectEqual(@as(u32, 7), value.id);
}

test "jzon: lastFailure, reports the byte the parse stopped at" {
    const Target = struct { id: u32 };

    const result = deserialize(Target, std.testing.allocator, "{\"id\":x}", .{
        .strategy = .GENERATED,
    });

    try std.testing.expectError(DeserializeError.Jzon_Deserialize_Unexpected, result);
    try std.testing.expectEqual(@as(usize, 6), lastFailure().offset);
}

test "jzon: SerializeStrategy, is the options record's strategy" {
    const options: SerializeOptions = .{ .strategy = SerializeStrategy.GENERATED };

    try std.testing.expectEqual(SerializeOptions.Strategy.GENERATED, options.strategy);
}

test "jzon: DeserializeStrategy, is the options record's strategy" {
    const options: DeserializeOptions = .{ .strategy = DeserializeStrategy.SCANNER };

    try std.testing.expectEqual(DeserializeOptions.Strategy.SCANNER, options.strategy);
}

test "jzon: Strings, is the options record's string mode" {
    const options: DeserializeOptions = .{ .strings = Strings.BORROW };

    try std.testing.expectEqual(DeserializeOptions.Strings.BORROW, options.strings);
}

test "jzon: Unknown, is the options record's unknown key mode" {
    const options: DeserializeOptions = .{ .unknown = Unknown.SKIP };

    try std.testing.expectEqual(DeserializeOptions.Unknown.SKIP, options.unknown);
}

test "jzon: SerializeError, is the serialize entry's set" {
    const err: SerializeError = error.Jzon_Serialize_NoSpaceLeft;
    var buf: [2]u8 = undefined;

    try std.testing.expectError(err, serialize(&buf, .{ .id = @as(u32, 7) }, .{}));
}

