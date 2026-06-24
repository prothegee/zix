//! zix HTTP/3 POOL dispatch: the v1 single-worker recv with internal CID demux. The worker-pool
//! distribution arrives with the v1 pooled tier (CID to worker dispatch).

const Config = @import("../config.zig");
const core = @import("../core.zig");
const common = @import("common.zig");

/// Run the HTTP/3 server with the v1 single worker (pooled distribution is a later tier).
pub fn runPool(comptime handler: core.HandlerFn, config: Config.Http3ServerConfig) !void {
    return common.runSingle(handler, config);
}
