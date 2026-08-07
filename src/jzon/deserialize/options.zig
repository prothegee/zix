//! zix jzon deserialize options.
//!
//! What:
//! - What a caller hands a parse, and what a parse can hand back. Every path
//!   reads the same options and reports the same errors, which is what lets one
//!   be swapped for another without a line changing around the call.

const std = @import("std");

/// Where a parsed string's bytes live.
pub const Strings = enum {
    /// Every string is copied into the allocator, so the value outlives the
    /// document it came from.
    COPY,
    /// A string with no escape in it points into the document instead of being
    /// copied. A string that carries an escape is still copied, because its
    /// decoded bytes are not in the document anywhere. The document has to
    /// outlive the value.
    BORROW,
};

/// What happens to a key the target type does not declare.
pub const Unknown = enum {
    /// The document is wrong for this type, so the parse fails.
    REJECT,
    /// The key and its whole value are stepped over, however deep they nest.
    SKIP,
};

/// The options a parse runs with.
pub const Options = struct {
    strings: Strings = .COPY,
    unknown: Unknown = .REJECT,
};

/// How a parse can fail.
///
/// Note:
/// - Every path maps onto this one set, so what a caller has to handle does not
///   change when the path under it does.
/// - Truncated means the document ended early. Unexpected means what is there is
///   not what the type wants: a syntax error, a value of the wrong shape, or the
///   same key twice.
/// - A path may never raise some of these. The std-backed one reports a bad
///   escape as a syntax error rather than as BadEscape, because std does not
///   separate the two. The set stays whole either way.
pub const Error = error{
    UnknownField,
    MissingField,
    UnknownEnumValue,
    Truncated,
    Unexpected,
    BadNumber,
    BadEscape,
    OutOfMemory,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix jzon: deserialize options default to the safe pair" {
    const options: Options = .{};

    try std.testing.expectEqual(Strings.COPY, options.strings);
    try std.testing.expectEqual(Unknown.REJECT, options.unknown);
}
