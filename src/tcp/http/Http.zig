//! zix http namespace

const config = @import("config.zig");
const response = @import("response.zig");
const request = @import("request.zig");
const context = @import("context.zig");
const router = @import("router.zig");
const content = @import("content.zig");
const upload = @import("upload.zig");

// --------------------------------------------------------- //

pub const Server = @import("server.zig").HttpServer;
pub const ServerConfig = config.HttpServerConfig;
pub const Request = request.Request;
pub const Response = response.Response;
pub const Context = context.Context;
pub const HandlerFn = router.HandlerFn;
pub const Header = response.HttpHeader;
pub const HeaderSize = response.HeaderSize;
pub const ContentType = content.Type;
pub const Content = content;
pub const Multipart = upload.MultipartParser;
pub const MultipartField = upload.MultipartField;
pub const WebSocket = @import("websocket.zig");
