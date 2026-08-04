// Test runner for zix.Webrtc (webrtc_datachannel_echo, UDP port 9083).
// Spawns the echo server, runs one whole session against it with the hand-rolled webrtc_client over
// a real loopback socket, asserts the message came back byte for byte, kills the server.
//
// Invoked by `zig build test-runner-webrtc`.
// argv[1]: server binary path, argv[2]: label, argv[3]: port (unused).
//
// Note:
// - This is the first check where two independent zix instances have to agree on every byte of four
//   protocols in a row: ICE, DTLS, SCTP, and DCEP. Everything under them was tested against itself,
//   so a disagreement shows up here and nowhere earlier.
// - WebRTC binds a UDP socket with no TCP accept to poll, so the server is given a short fixed
//   moment to bind, the same way the HTTP/3 and raw UDP runners do.

const std = @import("std");
const common = @import("common.zig");
const checks_webrtc = @import("checks_webrtc.zig");

const SERVER_PORT: u16 = 9083;

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) void {
    var arg_iter = common.argsIterator(process.minimal.args);
    _ = arg_iter.skip();
    const server_path = arg_iter.next() orelse {
        std.debug.print("FAIL webrtc: missing server path\n", .{});
        std.process.exit(1);
    };
    const label = arg_iter.next() orelse {
        std.debug.print("FAIL webrtc: missing label\n", .{});
        std.process.exit(1);
    };

    if (common.skipDispatchOffPlatform(label)) return;

    checks_webrtc.runWebrtc(process.io, server_path, SERVER_PORT) catch |err| {
        std.debug.print("FAIL {s}: {}\n", .{ label, err });
        std.process.exit(1);
    };

    common.printPass(label);
}
