//! zix HTTP/3 MIXED dispatch: the v1 single-worker recv with internal CID demux.

const Config = @import("../config.zig");
const core = @import("../core.zig");
const common = @import("common.zig");

/// Run the HTTP/3 server with the v1 single worker.
pub fn runMixed(comptime handler: core.HandlerFn, config: Config.Http3ServerConfig) !void {
    return common.runSingle(handler, config);
}
