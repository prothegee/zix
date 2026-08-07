//! zix jzon: JSON, in both directions.
//!
//! What:
//! - The surface a jzon caller reaches. Under it sit four pieces, each owning one
//!   concern: a bounds-checked write cursor, a bounds-checked read cursor, the
//!   string escape rules, and the integer paths.
//! - Nothing here allocates. A writer is handed a buffer it must fit in, a reader
//!   is handed a document it may not read past.

pub const sink = @import("sink.zig");
pub const cursor = @import("cursor.zig");
pub const escape = @import("escape.zig");
pub const integer = @import("integer.zig");

/// A write cursor over a caller-owned buffer.
pub const Sink = sink.Sink;

/// A read cursor over a caller-owned document.
pub const Cursor = cursor.Cursor;

/// A located string token: the bytes between the quotes, plus whether they hold
/// an escape.
pub const StringSpan = cursor.StringSpan;
