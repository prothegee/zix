//! ZIX example tls grpc basic
//!
//! ### file: examples/tls/tls_grpc_basic.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! gRPC over TLS with an ECDSA P-256 certificate, one unary route.
//!
//! ### note:
//!
//! The TLS context must offer ALPN h2. .EPOLL and .URING terminate TLS 1.3 in
//! the event loop. .ASYNC also serves TLS 1.2 clients.
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
const PORT:u16 = 9070;
const WORKERS:usize = 0;
const DISPATCH_MODEL:zix.Grpc.DispatchModel =
    if (builtin.os.tag == .linux) .URING else .ASYNC;
// Demo certificate (SAN localhost, 127.0.0.1). For a real domain, point CERT and
// KEY at the certbot files:
// CERT: /etc/letsencrypt/live/sub.domain.tld/fullchain.pem
// KEY: /etc/letsencrypt/live/sub.domain.tld/privkey.pem
const CERT:[]const u8 = "examples/certs/ecdsa_p256_cert.pem";
const KEY:[]const u8 = "examples/certs/ecdsa_p256_key.pem";

const CONTENT_TYPE:[]const u8 = "application/grpc+proto";

// --------------------------------------------------------- //

// grpcurl usage:
// grpcurl -insecure -proto examples/protobuf/helloworld.proto \
//   -d '{"name":"world"}' localhost:9070 helloworld.Greeter/SayHello
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
    var tls = try zix.tlz.Context.init(std.heap.smp_allocator, init.io, .{
        .cert_path = CERT,
        .key_path = KEY,
        .alpn = &.{.H2},
    });
    defer tls.deinit();

    var server = zix.Grpc.Server.init(Routes, .{
        .io = init.io,
        .ip = IP,
        .port = PORT,
        .tls = &tls,
        .workers = WORKERS,
        .dispatch_model = DISPATCH_MODEL,
    });
    defer server.deinit();

    try server.run();
}

