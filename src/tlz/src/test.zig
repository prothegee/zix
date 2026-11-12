//! TLZ unit and edge test
//!
//! ### file: src/tlz/src/test.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! TLZ unit and edge test entry: imports every source file so its tests run.
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

    _ = @import("wire/Reader.zig");
    _ = @import("wire/Writer.zig");
    _ = @import("alert.zig");
    _ = @import("alert/description.zig");
    _ = @import("alert/Inbound.zig");
    _ = @import("key_schedule.zig");
    _ = @import("key_schedule/Transcript.zig");
    _ = @import("record.zig");
    _ = @import("record/content_type.zig");
    _ = @import("record/Opened.zig");
    _ = @import("cipher_suite.zig");
    _ = @import("named_group.zig");
    _ = @import("signature_scheme.zig");
    _ = @import("extension_type.zig");
    _ = @import("alpn.zig");
}

