//! ZIX Http1
//!
//! ### file: src/zix/tcp/http1/Http1.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Zix Http1 namespace
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

const router = @import("router.zig");

// --------------------------------------------------------- //
// Public:

pub const Server = @import("Server.zig");
pub const DispatchModel = @import("../../shared/dispatch.zig").Model;

pub const Route = router.Route;
pub const Router = router.Router;
pub const RouteKind = router.RouteKind;

pub const Request = @import("Request.zig");
pub const Response = @import("Response.zig");
pub const Context = @import("Context.zig");

