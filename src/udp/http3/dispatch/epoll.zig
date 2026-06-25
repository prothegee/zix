//! zix HTTP/3 EPOLL dispatch: one SO_REUSEPORT worker per core, the kernel load-balancing connections
//! by 4-tuple (RC3 multicore).

const Config = @import("../config.zig");
const core = @import("../core.zig");
const common = @import("common.zig");

/// Run the HTTP/3 server with one SO_REUSEPORT worker per core.
pub fn runEpoll(comptime handler: core.HandlerFn, config: Config.Http3ServerConfig) !void {
    return common.runPerCore(handler, config);
}
