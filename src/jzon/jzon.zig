//! zix jzon: JSON, in both directions.
//!
//! What:
//! - The surface a jzon caller reaches. Under it sit the pieces, each owning one
//!   concern: a bounds-checked write cursor, a bounds-checked read cursor, the
//!   string escape rules and their vector scan, the integer paths, the float
//!   path, the questions a type is asked, and the ways a value is rendered and
//!   read back.
//! - Serialize allocates nothing: a writer is handed a buffer it must fit in.
//!   Deserialize allocates only what the result points at, out of the allocator
//!   the caller hands over.

pub const sink = @import("sink.zig");
pub const cursor = @import("cursor.zig");
pub const escape = @import("escape.zig");
pub const escape_vector = @import("escape_vector.zig");
pub const integer = @import("integer.zig");
pub const float = @import("float.zig");
pub const reflect = @import("reflect.zig");

/// Render a value the way std does, which takes every shape std takes.
pub const std_emitter = @import("serialize/std_emitter.zig");

/// Render a value through code generated from its type.
pub const generated_emitter = @import("serialize/generated_emitter.zig");

/// What a caller hands a parse, and what a parse can hand back.
pub const deserialize_options = @import("deserialize/options.zig");

/// Which of a target's fields a document filled in.
pub const fields = @import("deserialize/fields.zig");

/// Read a value the way std does, which parses every shape std parses.
pub const std_parser = @import("deserialize/std_parser.zig");

/// Read a value through std's tokens and dispatch generated from the type.
pub const scanner_parser = @import("deserialize/scanner_parser.zig");

/// A write cursor over a caller-owned buffer.
pub const Sink = sink.Sink;

/// A read cursor over a caller-owned document.
pub const Cursor = cursor.Cursor;

/// A located string token: the bytes between the quotes, plus whether they hold
/// an escape.
pub const StringSpan = cursor.StringSpan;

/// The options every deserialize path reads.
pub const DeserializeOptions = deserialize_options.Options;

/// The one error set every deserialize path reports through.
pub const DeserializeError = deserialize_options.Error;
