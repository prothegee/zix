//! zix HTTP/3 EPOLL dispatch: per-core SO_REUSEPORT CID steering is v2 (ADR-049 phase 3), so this
//! folds to the v1 single worker with a logged notice.

const Config = @import("../config.zig");
const core = @import("../core.zig");
const common = @import("common.zig");

/// Run the HTTP/3 server. Folds to the v1 single worker until per-core CID steering lands.
pub fn runEpoll(comptime handler: core.HandlerFn, config: Config.Http3ServerConfig) !void {
    return common.runPerCore(handler, config);
}
