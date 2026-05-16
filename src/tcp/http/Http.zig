//! zix http namespace

const config = @import("config.zig");
const client_config = @import("client_config.zig");
const client = @import("client.zig");
const response = @import("response.zig");
const request = @import("request.zig");
const context = @import("context.zig");
const router = @import("router.zig");
const content = @import("content.zig");
const upload = @import("upload.zig");

// --------------------------------------------------------- //

pub const Server = @import("server.zig").Server;
pub const ServerConfig = config.HttpServerConfig;
pub const DispatchModel = config.DispatchModel;
pub const Client = client.HttpClient;
pub const ClientConfig = client_config.HttpClientConfig;
pub const default_user_agent = client_config.user_agent;
pub const ClientResponse = client.ClientResponse;
pub const ClientRequestOpts = client.RequestOpts;
pub const Request = request.Request;
pub const Response = response.Response;
pub const SseWriter = response.SseWriter;
// Do we need WebSocketWriter for some reason?
pub const Context = context.Context;
pub const HandlerFn = router.HandlerFn;
pub const Header = response.HttpHeader;
pub const HeaderSize = response.HeaderSize;
pub const RequestHeaderSize = @import("parser.zig").RequestHeaderSize;
pub const ContentType = content.Type;
pub const Content = content;
pub const Multipart = upload.MultipartParser;
pub const MultipartField = upload.MultipartField;
pub const WebSocket = @import("websocket.zig");
