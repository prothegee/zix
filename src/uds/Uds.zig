//! zix uds namespace aggregator

const config = @import("config.zig");

// --------------------------------------------------------- //

pub const ServerConfig = config.UdsServerConfig;
pub const ClientConfig = config.UdsClientConfig;

// --------------------------------------------------------- //

/// UDS stream server.
/// Example: var server = try zix.Uds.Server.init(.{ .path = "/tmp/app.sock", .allocator = alloc });
pub const Server = @import("server.zig").UdsServer;

/// UDS stream client.
/// Example: var client = try zix.Uds.Client.connect(.{ .path = "/tmp/app.sock" }, io);
pub const Client = @import("client.zig").UdsClient;

/// Connection handler function type for custom server behavior.
pub const HandlerFn = @import("server.zig").HandlerFn;

/// Default echo handler: reads length-prefixed frames and echoes each back.
pub const echoHandler = @import("server.zig").echoHandler;
