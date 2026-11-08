//! JZON fields
//!
//! ### file: src/jzon/src/deserialize/fields.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Which of a target struct's fields a document has filled in, and what happens to
//! the ones it left out. Every generated parser asks the same two questions.
//!
//! ### note:
//!
//! A field with no declared default has nothing to fall back to, so an absent one
//! fails. An optional field is no exception: spell it `note: ?[]const u8 = null` to make
//! the document's silence mean null. That is the rule std.json holds to.
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
const Failure = @import("Failure.zig");
const reflect = @import("../reflect.zig");

// --------------------------------------------------------- //
// Public:

/// How the bookkeeping can fail.
///
/// Note:
/// - Unexpected means the same key came twice. MissingField means a field the
///   document never carried declares no default. MissingField also records the field
///   name for `lastFailure`.
pub const Error = error{
    Jzon_Fields_Unexpected,
    Jzon_Fields_MissingField,
};

/// Tracks which of a target's fields have been read.
///
/// Note:
/// - One bool per field, sized at compile time, so nothing is allocated to track a
///   parse.
///
/// Param:
/// Target - type (comptime, the struct being built)
///
/// Usage:
/// ```zig
/// var seen: fields.Seen(Order) = .{};
///
/// try seen.mark(index);
/// try seen.fill(&result);
/// ```
///
/// Return:
/// - type (the tracker for `Target`)
pub fn Seen(comptime Target: type) type {
    return struct {
        const Tracker = @This();

        /// How many fields the target declares.
        pub const COUNT = std.meta.fieldNames(Target).len;

        /// One flag per field, in declaration order.
        marked: [COUNT]bool = @splat(false),

        /// Record that the field at `index` has been read.
        ///
        /// Note:
        /// - A field read twice means the document carried the same key twice, which
        ///   no JSON object should. Reporting it here keeps the check in one place.
        ///
        /// Param:
        /// index - usize (the field's place in declaration order)
        ///
        /// Return:
        /// - void
        /// - Error.Jzon_Fields_Unexpected when that field was already read
        pub fn mark(self: *Tracker, index: usize) Error!void {
            if (self.marked[index]) return Error.Jzon_Fields_Unexpected;

            self.marked[index] = true;
        }

        /// Whether the field at `index` has been read.
        ///
        /// Param:
        /// index - usize (the field's place in declaration order)
        ///
        /// Return:
        /// - bool (true when `mark` already ran for it)
        pub fn isMarked(self: Tracker, index: usize) bool {
            return self.marked[index];
        }

        /// Give every field the document left out the default its type declares.
        ///
        /// Note:
        /// - Fields are walked in declaration order, so the walk stops at the first
        ///   one it cannot answer for, even when a later one has a default.
        ///
        /// Param:
        /// target - *Target (the value being built, whose unread fields are still
        ///   undefined)
        ///
        /// Return:
        /// - void
        /// - Error.Jzon_Fields_MissingField when an unread field declares no default
        pub fn fill(self: Tracker, target: *Target) Error!void {
            inline for (comptime std.meta.fieldNames(Target), 0..) |name, index| {
                if (!self.marked[index]) {
                    const declared = reflect.defaultOf(Target, index) orelse {
                        Failure.noteField(name);

                        return Error.Jzon_Fields_MissingField;
                    };

                    @field(target, name) = declared;
                }
            }
        }
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Record = struct {
    id: u32,
    name: []const u8,
    note: ?[]const u8 = null,
    retries: u8 = 3,
};

const Pair = struct {
    left: u8,
    right: u8 = 2,
};

/// An optional with no default is still a field the document owes, which is the rule
/// std.json holds to.
const Bare = struct {
    note: ?[]const u8,
};

/// The same field with a default of null, which is how a field is made optional in the
/// document.
const Defaulted = struct {
    note: ?[]const u8 = null,
};

test "jzon deserialize: fields, Seen counts the target fields" {
    try std.testing.expectEqual(@as(usize, 4), Seen(Record).COUNT);
}

test "jzon deserialize: fields, Seen starts with nothing read" {
    const seen: Seen(Record) = .{};

    for (0..Seen(Record).COUNT) |index| {
        try std.testing.expect(!seen.isMarked(index));
    }
}

test "jzon deserialize: fields, mark records the field as read" {
    var seen: Seen(Record) = .{};

    try seen.mark(1);

    try std.testing.expect(seen.isMarked(1));
}

test "jzon deserialize: fields, mark of the same field twice is unexpected" {
    var seen: Seen(Record) = .{};

    try seen.mark(0);

    try std.testing.expectError(Error.Jzon_Fields_Unexpected, seen.mark(0));
}

test "jzon deserialize: fields, fill gives the left out fields their defaults" {
    var seen: Seen(Record) = .{};
    try seen.mark(0);
    try seen.mark(1);

    var record: Record = undefined;
    record.id = 7;
    record.name = "x";

    try seen.fill(&record);

    try std.testing.expectEqual(@as(u32, 7), record.id);
    try std.testing.expectEqualStrings("x", record.name);
    try std.testing.expect(record.note == null);
    try std.testing.expectEqual(@as(u8, 3), record.retries);
}

test "jzon deserialize: fields, fill of a field without a default is missing field" {
    var seen: Seen(Record) = .{};
    try seen.mark(0);

    var record: Record = undefined;
    record.id = 7;

    try std.testing.expectError(Error.Jzon_Fields_MissingField, seen.fill(&record));
}

test "jzon deserialize: fields, missing field records its name for lastFailure" {
    Failure.reset();

    var seen: Seen(Record) = .{};
    try seen.mark(0);

    var record: Record = undefined;
    record.id = 7;

    try std.testing.expectError(Error.Jzon_Fields_MissingField, seen.fill(&record));
    try std.testing.expectEqualStrings("name", Failure.lastFailure().field);
}

test "jzon deserialize: fields, refused second mark keeps the first" {
    var seen: Seen(Pair) = .{};

    try seen.mark(1);
    try std.testing.expectError(Error.Jzon_Fields_Unexpected, seen.mark(1));

    try std.testing.expect(seen.isMarked(1));
}

test "jzon deserialize: fields, Seen over a target without fields fills nothing" {
    const Empty = struct {};

    const seen: Seen(Empty) = .{};
    var empty: Empty = .{};

    try seen.fill(&empty);
    try std.testing.expectEqual(@as(usize, 0), Seen(Empty).COUNT);
}

test "jzon deserialize: fields, optional without a default is missing field" {
    const seen: Seen(Bare) = .{};
    var bare: Bare = undefined;

    try std.testing.expectError(Error.Jzon_Fields_MissingField, seen.fill(&bare));
}

test "jzon deserialize: fields, optional with a default of null gets its null" {
    const seen: Seen(Defaulted) = .{};
    var defaulted: Defaulted = undefined;

    try seen.fill(&defaulted);

    try std.testing.expect(defaulted.note == null);
}

test "jzon deserialize: fields, fill stops at the first field it cannot answer for" {
    // `right` has a default and comes second, `left` has none and comes first, so the
    // walk fails before it reaches the one it could have filled.
    const seen: Seen(Pair) = .{};
    var pair: Pair = undefined;

    try std.testing.expectError(Error.Jzon_Fields_MissingField, seen.fill(&pair));
}

test "jzon deserialize: fields, fill after the owed field is marked uses the default" {
    var seen: Seen(Pair) = .{};
    try seen.mark(0);

    var pair: Pair = undefined;
    pair.left = 1;

    try seen.fill(&pair);

    try std.testing.expectEqual(@as(u8, 1), pair.left);
    try std.testing.expectEqual(@as(u8, 2), pair.right);
}

test "jzon deserialize: fields, two trackers over one target keep their own marks" {
    var first: Seen(Pair) = .{};
    const second: Seen(Pair) = .{};

    try first.mark(0);

    try std.testing.expect(first.isMarked(0));
    try std.testing.expect(!second.isMarked(0));
}

