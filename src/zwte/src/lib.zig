//! zwte: jwt & jwe (zix internal implementation)

const std = @import("std");

// --------------------------------------------------------- //

pub const base64url = @import("base64url.zig");
pub const claims = @import("claims.zig");
pub const hmac = @import("hmac.zig");
pub const jwt = @import("jwt.zig");

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zwte: unit test" {
    std.testing.refAllDecls(@import("base64url.zig"));
    std.testing.refAllDecls(@import("claims.zig"));
    std.testing.refAllDecls(@import("hmac.zig"));
    std.testing.refAllDecls(@import("jwt.zig"));
}
