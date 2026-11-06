//! ZIX unit and edge test
//!
//! ### file: src/zix/test.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! ZIX unit and edge test entry: imports every source file so its tests run.
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

const builtin = @import("builtin");

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test {
    _ = @import("lib.zig");
    _ = @import("multiplexers/slab.zig");
    _ = @import("shared/dispatch.zig");
    _ = @import("tcp/http1/BodyInfo.zig");
    _ = @import("tcp/http1/ChunkedFrame.zig");
    _ = @import("tcp/http1/ChunkedRead.zig");
    _ = @import("tcp/http1/Config.zig");
    _ = @import("tcp/http1/ConnArgs.zig");
    _ = @import("tcp/http1/ConnEntry.zig");
    _ = @import("tcp/http1/ConnRegistry.zig");
    _ = @import("tcp/http1/Context.zig");
    _ = @import("tcp/http1/HeaderSpan.zig");
    _ = @import("tcp/http1/Http1.zig");
    _ = @import("tcp/http1/HttpHeader.zig");
    _ = @import("tcp/http1/ParseResult.zig");
    _ = @import("tcp/http1/ParsedHead.zig");
    _ = @import("tcp/http1/PathParam.zig");
    _ = @import("tcp/http1/Request.zig");
    _ = @import("tcp/http1/RespSink.zig");
    _ = @import("tcp/http1/Response.zig");
    _ = @import("tcp/http1/ServeOpts.zig");
    _ = @import("tcp/http1/Server.zig");
    _ = @import("tcp/http1/SseWriter.zig");
    _ = @import("tcp/http1/cache.zig");
    _ = @import("tcp/http1/chunk.zig");
    _ = @import("tcp/http1/compress.zig");
    _ = @import("tcp/http1/connection.zig");
    _ = @import("tcp/http1/date.zig");
    _ = @import("tcp/http1/dispatch/async.zig");
    if (builtin.target.os.tag == .linux) {
        _ = @import("tcp/http1/dispatch/epoll.zig");
        _ = @import("tcp/http1/dispatch/uring.zig");
    }
    _ = @import("tcp/http1/dispatch/common.zig");
    _ = @import("tcp/http1/handler.zig");
    _ = @import("tcp/http1/head.zig");
    _ = @import("tcp/http1/header.zig");
    _ = @import("tcp/http1/parser.zig");
    _ = @import("tcp/http1/reader.zig");
    _ = @import("tcp/http1/router.zig");
    _ = @import("tcp/http1/serve.zig");
    _ = @import("tcp/http1/writer.zig");
    _ = @import("utils/ResponseCache.zig");
    _ = @import("utils/compression/compression.zig");
    _ = @import("utils/date_and_time.zig");
    _ = @import("utils/http/content.zig");
    _ = @import("utils/http/encoding.zig");
    _ = @import("utils/http/method.zig");
    _ = @import("utils/http/status.zig");
    _ = @import("utils/media_type.zig");
    _ = @import("utils/peer_address.zig");
    _ = @import("utils/socket/pair.zig");
}

