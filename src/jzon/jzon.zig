//! zix jzon: JSON, in both directions.
//!
//! What:
//! - The surface a jzon caller reaches. Under it sit the pieces, each owning one
//!   concern: a bounds-checked write cursor, a bounds-checked read cursor, the
//!   string escape rules and their vector scan, the integer paths, the float
//!   path, and the two ways a value is rendered.
//! - Nothing here allocates. A writer is handed a buffer it must fit in, a reader
//!   is handed a document it may not read past.

pub const sink = @import("sink.zig");
pub const cursor = @import("cursor.zig");
pub const escape = @import("escape.zig");
pub const escape_vector = @import("escape_vector.zig");
pub const integer = @import("integer.zig");
pub const float = @import("float.zig");

/// Render a value the way std does, which takes every shape std takes.
pub const std_emitter = @import("serialize/std_emitter.zig");

/// Render a value through code generated from its type.
pub const generated_emitter = @import("serialize/generated_emitter.zig");

/// A write cursor over a caller-owned buffer.
pub const Sink = sink.Sink;

/// A read cursor over a caller-owned document.
pub const Cursor = cursor.Cursor;

/// A located string token: the bytes between the quotes, plus whether they hold
/// an escape.
pub const StringSpan = cursor.StringSpan;
