//! zix udp raw-bytes POOL dispatch (ADR-049): a single recvmmsg worker on the calling thread.

const Config = @import("../config.zig");
const core = @import("../core.zig");
const common = @import("common.zig");

/// Run the raw server with a single worker.
pub fn runPool(comptime handler: core.HandlerFn, config: Config.UdpServerConfig) !void {
    return common.runSingle(handler, config);
}
