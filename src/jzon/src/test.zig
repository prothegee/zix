//! JZON unit and edge test
//!
//! ### file: src/jzon/src/test.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! JZON unit and edge test entry: imports every source file so its tests run.
//!
//! ### note:
//!
//! A test root only collects tests from itself and files it imports by path.
//! Tests inside an imported module are skipped, so every file is imported here.
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

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test {
    _ = @import("lib.zig");
    _ = @import("Cursor.zig");
    _ = @import("Sink.zig");
    _ = @import("StringSpan.zig");
    _ = @import("cursor_vector.zig");
    _ = @import("escape.zig");
    _ = @import("escape_vector.zig");
    _ = @import("float.zig");
    _ = @import("integer.zig");
    _ = @import("lane.zig");
    _ = @import("reflect.zig");
    _ = @import("deserialize/Failure.zig");
    _ = @import("serialize/EmitShape.zig");
    _ = @import("serialize/SerializeOptions.zig");
    _ = @import("serialize/generated_emitter.zig");
    _ = @import("serialize/serialize.zig");
    _ = @import("serialize/std_emitter.zig");
}

