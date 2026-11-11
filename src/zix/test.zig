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
    _ = @import("logger/FileSink.zig");
    _ = @import("logger/Flusher.zig");
    _ = @import("logger/Logger.zig");
    _ = @import("logger/Sink.zig");
    _ = @import("logger/Timestamp.zig");
    _ = @import("logger/format.zig");
    _ = @import("logger/windows_file.zig");
    _ = @import("multiplexers/cpu_affinity.zig");
    _ = @import("multiplexers/reuseport.zig");
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
    _ = @import("tcp/http1/handler.zig");
    _ = @import("tcp/http1/head.zig");
    _ = @import("tcp/http1/header.zig");
    _ = @import("tcp/http1/log.zig");
    _ = @import("tcp/http1/parser.zig");
    _ = @import("tcp/http1/reader.zig");
    _ = @import("tcp/http1/router.zig");
    _ = @import("tcp/http1/serve.zig");
    _ = @import("tcp/http1/static.zig");
    _ = @import("tcp/http1/writer.zig");
    _ = @import("tcp/http1/websocket.zig");
    _ = @import("tcp/http1/websocket/WebSocketPending.zig");
    _ = @import("tcp/http1/websocket/WsFrame.zig");
    _ = @import("tcp/http1/websocket/WsParseResult.zig");
    _ = @import("tcp/http1/websocket/WsPumpResult.zig");
    _ = @import("tcp/http1/websocket/WsRingPumpResult.zig");
    _ = @import("tcp/http1/websocket/WsSendSink.zig");
    _ = @import("tcp/http1/websocket/frame.zig");
    _ = @import("tcp/http1/websocket/frame_fn.zig");
    _ = @import("tcp/http1/websocket/opcode.zig");
    _ = @import("tcp/http1/websocket/pending.zig");
    _ = @import("tcp/http1/websocket/pump.zig");
    _ = @import("tcp/http1/websocket/send.zig");
    _ = @import("tcp/http1/websocket/upgrade.zig");
    _ = @import("tcp/http2/CoalesceSink.zig");
    _ = @import("tcp/http2/Config.zig");
    _ = @import("tcp/http2/Context.zig");
    _ = @import("tcp/http2/FrameHeader.zig");
    _ = @import("tcp/http2/Http2.zig");
    _ = @import("tcp/http2/Request.zig");
    _ = @import("tcp/http2/Response.zig");
    _ = @import("tcp/http2/ServeOpts.zig");
    _ = @import("tcp/http2/Server.zig");
    _ = @import("tcp/http2/Stream.zig");
    _ = @import("tcp/http2/UpgradeHead.zig");
    _ = @import("tcp/http2/cache.zig");
    _ = @import("tcp/http2/coalesce.zig");
    _ = @import("tcp/http2/control.zig");
    _ = @import("tcp/http2/declared.zig");
    _ = @import("tcp/http2/dispatch/async.zig");
    _ = @import("tcp/http2/dispatch/epoll.zig");
    _ = @import("tcp/http2/dispatch/uring.zig");
    _ = @import("tcp/http2/grpc/Config.zig");
    _ = @import("tcp/http2/grpc/ConnMutex.zig");
    _ = @import("tcp/http2/grpc/ConnReader.zig");
    _ = @import("tcp/http2/grpc/Context.zig");
    _ = @import("tcp/http2/grpc/DispatchTask.zig");
    _ = @import("tcp/http2/grpc/GrpcPath.zig");
    _ = @import("tcp/http2/grpc/ReplyStage.zig");
    _ = @import("tcp/http2/grpc/Request.zig");
    _ = @import("tcp/http2/grpc/Response.zig");
    _ = @import("tcp/http2/grpc/ServeOpts.zig");
    _ = @import("tcp/http2/grpc/Stream.zig");
    _ = @import("tcp/http2/grpc/cache.zig");
    _ = @import("tcp/http2/grpc/content_type.zig");
    _ = @import("tcp/http2/grpc/deadline.zig");
    _ = @import("tcp/http2/grpc/encoding.zig");
    _ = @import("tcp/http2/grpc/frame/GrpcPrefix.zig");
    _ = @import("tcp/http2/grpc/frame/build.zig");
    _ = @import("tcp/http2/grpc/frame/gzip.zig");
    _ = @import("tcp/http2/grpc/frame/prefix.zig");
    _ = @import("tcp/http2/grpc/frame/reply_block.zig");
    _ = @import("tcp/http2/grpc/frame/send.zig");
    _ = @import("tcp/http2/grpc/handler.zig");
    _ = @import("tcp/http2/grpc/path.zig");
    _ = @import("tcp/http2/grpc/proto/MessageReader.zig");
    _ = @import("tcp/http2/grpc/proto/ProtoField.zig");
    _ = @import("tcp/http2/grpc/proto/field.zig");
    _ = @import("tcp/http2/grpc/proto/varint.zig");
    _ = @import("tcp/http2/grpc/proto/wire_type.zig");
    _ = @import("tcp/http2/grpc/router.zig");
    _ = @import("tcp/http2/grpc/serve.zig");
    _ = @import("tcp/http2/grpc/status.zig");
    _ = @import("tcp/http2/grpc/stream_dispatch.zig");
    _ = @import("tcp/http2/grpc/stream_slot.zig");
    _ = @import("tcp/http2/grpc/timeout.zig");
    _ = @import("tcp/http2/grpc/window.zig");
    _ = @import("tcp/http2/hpack/DynamicTable.zig");
    _ = @import("tcp/http2/hpack/Header.zig");
    _ = @import("tcp/http2/hpack/HpackDecoder.zig");
    _ = @import("tcp/http2/hpack/HpackEncoder.zig");
    _ = @import("tcp/http2/hpack/HuffSym.zig");
    _ = @import("tcp/http2/hpack/RespPrefix.zig");
    _ = @import("tcp/http2/hpack/huffman.zig");
    _ = @import("tcp/http2/hpack/huffman_table.zig");
    _ = @import("tcp/http2/hpack/integer.zig");
    _ = @import("tcp/http2/hpack/response_block.zig");
    _ = @import("tcp/http2/hpack/static_table.zig");
    _ = @import("tcp/http2/frame.zig");
    _ = @import("tcp/http2/frame_payload.zig");
    _ = @import("tcp/http2/handler.zig");
    _ = @import("tcp/http2/log.zig");
    _ = @import("tcp/http2/peer_settings.zig");
    _ = @import("tcp/http2/mux/MuxConn.zig");
    _ = @import("tcp/http2/mux/MuxStream.zig");
    _ = @import("tcp/http2/mux/conn_outcome.zig");
    _ = @import("tcp/http2/mux/flow.zig");
    _ = @import("tcp/http2/mux/frame_loop.zig");
    _ = @import("tcp/http2/mux/mux_dispatch.zig");
    _ = @import("tcp/http2/mux/mux_phase.zig");
    _ = @import("tcp/http2/mux/mux_upgrade.zig");
    _ = @import("tcp/http2/mux/process.zig");
    _ = @import("tcp/http2/mux/send_stream.zig");
    _ = @import("tcp/http2/mux/stream_pool.zig");
    _ = @import("tcp/http2/reader.zig");
    _ = @import("tcp/http2/router.zig");
    _ = @import("tcp/http2/send_best_effort.zig");
    _ = @import("tcp/http2/serve.zig");
    _ = @import("tcp/http2/static.zig");
    _ = @import("tcp/http2/stream_body.zig");
    _ = @import("tcp/http2/stream_invoke.zig");
    _ = @import("tcp/http2/stream_slot.zig");
    _ = @import("tcp/http2/stream_state.zig");
    _ = @import("tcp/http2/upgrade.zig");
    _ = @import("tcp/http2/writer.zig");
    _ = @import("utils/Multipart.zig");
    _ = @import("utils/MultipartField.zig");
    _ = @import("utils/cache/ResponseCache.zig");
    _ = @import("utils/cache/async.zig");
    _ = @import("utils/cache/CacheEntry.zig");
    _ = @import("utils/cache/CacheRegistry.zig");
    _ = @import("utils/available.zig");
    _ = @import("utils/base32.zig");
    _ = @import("utils/base64.zig");
    _ = @import("utils/charsets.zig");
    _ = @import("utils/compression/brotli/BitReader.zig");
    _ = @import("utils/compression/brotli/BitWriter.zig");
    _ = @import("utils/compression/brotli/BlockCategory.zig");
    _ = @import("utils/compression/brotli/Command.zig");
    _ = @import("utils/compression/brotli/Decoder.zig");
    _ = @import("utils/compression/brotli/DictIndex.zig");
    _ = @import("utils/compression/brotli/DistanceRing.zig");
    _ = @import("utils/compression/brotli/HuffmanDecoder.zig");
    _ = @import("utils/compression/brotli/LitModel.zig");
    _ = @import("utils/compression/brotli/TreeCode.zig");
    _ = @import("utils/compression/brotli/brotli.zig");
    _ = @import("utils/compression/brotli/context.zig");
    _ = @import("utils/compression/brotli/dictionary.zig");
    _ = @import("utils/compression/brotli/distance.zig");
    _ = @import("utils/compression/brotli/encoder.zig");
    _ = @import("utils/compression/brotli/huffman.zig");
    _ = @import("utils/compression/brotli/dictionary_gen.zig");
    _ = @import("utils/compression/brotli/prefix_read.zig");
    _ = @import("utils/compression/brotli/prefix_write.zig");
    _ = @import("utils/compression/brotli/tables.zig");
    _ = @import("utils/compression/brotli/transform.zig");
    _ = @import("utils/compression/compression.zig");
    _ = @import("utils/compression/flate/FastBitWriter.zig");
    _ = @import("utils/compression/flate/flate.zig");
    _ = @import("utils/compression/flate/flate_fast.zig");
    _ = @import("utils/compression/level.zig");
    _ = @import("utils/compression/negotiate.zig");
    _ = @import("utils/compression/policy.zig");
    _ = @import("utils/date_and_time.zig");
    _ = @import("utils/file.zig");
    _ = @import("utils/generator.zig");
    _ = @import("utils/http/content.zig");
    _ = @import("utils/http/encoding.zig");
    _ = @import("utils/http/method.zig");
    _ = @import("utils/http/Range.zig");
    _ = @import("utils/http/RangeSpec.zig");
    _ = @import("utils/http/range_header.zig");
    _ = @import("utils/http/status.zig");
    _ = @import("utils/media_type.zig");
    _ = @import("utils/peer_address.zig");
    _ = @import("utils/pwhash/argon2.zig");
    _ = @import("utils/pwhash/bcrypt.zig");
    _ = @import("utils/pwhash/pbkdf2.zig");
    _ = @import("utils/pwhash/scrypt.zig");
    _ = @import("utils/socket/pair.zig");
    _ = @import("utils/static/StaticCache.zig");
    _ = @import("utils/static/StaticCacheRegistry.zig");
    _ = @import("utils/static/StaticHit.zig");
    _ = @import("utils/static/StaticSibling.zig");
    _ = @import("utils/static/StaticSlot.zig");
    _ = @import("utils/static/StaticVariant.zig");
    _ = @import("utils/static/cache_descriptor.zig");
    _ = @import("utils/static/cache_header.zig");
    _ = @import("utils/static/cache_path.zig");
    _ = @import("utils/static/install_result.zig");
    _ = @import("utils/static/static.zig");
    _ = @import("utils/check/string.zig");
}

