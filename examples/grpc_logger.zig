//! ZIX example grpc logger
//!
//! ### file: examples/grpc_logger.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! gRPC h2c server example with the zix Logger attached (console and file output).
//!
//! ### note:
//!
//! The engine writes one rpc line per call and the system lines for the server
//! lifecycle. The handler itself logs nothing.
//! The logger does not create its directory, so main creates LOG_DIR first.
//! The logger must outlive the server: it is declared first, so its deinit runs last.
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
const zix = @import("zix");

const builtin = @import("builtin");

// --------------------------------------------------------- //

const IP:[]const u8 = "127.0.0.1";
const PORT:u16 = 9035;
const WORKERS:usize = 0;
const KERNEL_BACKLOG:u31 = 1024;
const DISPATCH_MODEL:zix.Grpc.DispatchModel =
    if (builtin.os.tag == .linux) .URING else .ASYNC;

const LOG_DIR:[]const u8 = "./logs";
const LOG_FILE:[]const u8 = "grpc";

const CONTENT_TYPE:[]const u8 = "application/grpc+proto";

// --------------------------------------------------------- //

// The rpc line for this call is written by the engine.
//
// grpcurl usage:
// grpcurl -proto examples/protobuf/helloworld.proto -plaintext \
//   -d '{"name":"world"}' 127.0.0.1:9035 helloworld.Greeter/SayHello
fn sayHelloHandler(req: *zix.Grpc.Request, res: *zix.Grpc.Response, _: *zix.Grpc.Context) !void {
    const msg = req.recvMessage() orelse {
        try res.finish(.INVALID_ARGUMENT, "empty request");
        return;
    };

    // HelloReq fields: 1 - name (string)
    var name: []const u8 = "stranger";
    var reader = zix.Grpc.MessageReader.init(msg);
    while (true) {
        const field = reader.next() catch {
            try res.finish(.INVALID_ARGUMENT, "malformed request");
            return;
        } orelse break;

        if (field.field_number == 1) name = field.payload;
    }

    var text_buf: [256]u8 = undefined;
    const greeting = std.fmt.bufPrint(&text_buf, "Hello, {s}!", .{name}) catch "Hello!";

    // HelloResp fields: 1 - message (string)
    var resp_buf: [300]u8 = undefined;
    const resp_len = try zix.Grpc.encodeString(1, greeting, &resp_buf);

    try res.sendMessage(CONTENT_TYPE, resp_buf[0..resp_len]);
    try res.finish(.OK, "");
}

// --------------------------------------------------------- //

const Routes = zix.Grpc.Router(&[_]zix.Grpc.Route{
    .{
        .path = "/helloworld.Greeter/SayHello",
        .handler = sayHelloHandler,
    },
});

pub fn main(init: std.process.Init) !void {
    try std.Io.Dir.cwd().createDirPath(init.io, LOG_DIR);

    var logger = try zix.Logger.init(std.heap.smp_allocator, .{
        .console = .ALWAYS,
        .console_min_level = .INFO,
        .save_path = LOG_DIR,
        .save_file = LOG_FILE,
        .save_min_level = .INFO,
    });
    defer {
        logger.flush();
        logger.deinit();
    }

    var server = zix.Grpc.Server.init(Routes, .{
        .io = init.io,
        .ip = IP,
        .port = PORT,
        .workers = WORKERS,
        .kernel_backlog = KERNEL_BACKLOG,
        .dispatch_model = DISPATCH_MODEL,
        .logger = &logger,
    });
    defer server.deinit();

    try server.run();
}

