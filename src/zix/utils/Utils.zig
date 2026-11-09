//! ZIX Utils
//!
//! ### file: src/zix/utils/Utils.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! ZIX Utils namespace access
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

// --------------------------------------------------------- //
// Public:

/// ZIX Utils available check
pub const Available = @import("available.zig");

/// ZIX Utils base32
pub const Base32 = @import("base32.zig");

/// ZIX Utils base64
pub const Base64 = @import("base64.zig");

/// ZIX Utils charsets
pub const Charsets = @import("charsets.zig");

/// ZIX Utils check string
pub const CheckString = @import("check/string.zig");

/// ZIX Utils compression: codecs, negotiation, and the encode facade
pub const compression = @import("compression/compression.zig");

/// ZIX Utils date and time
pub const DateTime = @import("date_and_time.zig");

/// ZIX Utils file
pub const File = @import("file.zig");

/// ZIX Utils multipart/form-data parser
pub const Multipart = @import("Multipart.zig");

/// ZIX Utils one parsed multipart/form-data part
pub const MultipartField = @import("MultipartField.zig");

/// ZIX Utils generator
pub const Generator = @import("generator.zig");

/// ZIX Utils password hash
pub const Pwhash = struct {
    pub const Argon2 = @import("pwhash/argon2.zig");
    pub const Bcrypt = @import("pwhash/bcrypt.zig");
    pub const Pbkdf2 = @import("pwhash/pbkdf2.zig");
    pub const Scrypt = @import("pwhash/scrypt.zig");
};

