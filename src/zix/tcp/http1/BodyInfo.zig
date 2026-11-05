//! ZIX Http1 BodyInfo
//!
//! ### file: src/zix/tcp/http1/BodyInfo.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! What a dispatch model measured about the body it just read, for the request
//! it is about to invoke.
//! 
//! ### note:
//! 
//! - Only set when the delivered slice does not tell the whole story: a body the
//!   engine consumed past what it could hand over, or one the peer cut short.
//!   A body that arrived whole and fits the buffer needs no entry, Request.init
//!   already derives both answers from the slice.
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
// Fields:

/// Body bytes taken off the socket, counted from the reads that took them
/// and never from the Content-Length header.
received: u64,
/// Whether those reads reached the end of the body: the declared length, or
/// the chunked terminator.
complete: bool,

