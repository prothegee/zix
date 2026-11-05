//! ZIX utils http encoding
//!
//! ### file: src/zix/utils/http/encoding.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! n/a
//! 
//! ### note:
//! 
//! n/a
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

// --------------------------------------------------------- //
// Public:

/// ZIX HTTP content coding.
pub const Encoding = enum(u8) {
    IDENTITY,
    GZIP,
    DEFLATE,
    BR,

    /// The Accept-Encoding / Content-Encoding token for this coding.
    ///
    /// Return:
    /// - []const u8
    pub fn token(self: Encoding) []const u8 {
        return switch (self) {
            .IDENTITY => "identity",
            .GZIP => "gzip",
            .DEFLATE => "deflate",
            .BR => "br",
        };
    }

    /// The Content-Encoding header value to emit, or null for identity (no header).
    ///
    /// Return:
    /// - []const u8 for a real coding
    /// - null for identity, where no Content-Encoding header is sent
    pub fn contentEncoding(self: Encoding) ?[]const u8 {
        return if (self == .IDENTITY) null else self.token();
    }
};

