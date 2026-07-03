//! zix udp raw-bytes POOL dispatch (ADR-049 / ADR-050): multi-core, one SO_REUSEPORT recvmmsg worker
//! per CPU.

const Config = @import("../config.zig");
const core = @import("../core.zig");
const common = @import("common.zig");

/// Run the raw server with one SO_REUSEPORT recvmmsg worker per CPU (multi-core).
pub fn runPool(comptime handler: core.HandlerFn, config: Config.UdpServerConfig) !void {
    return common.runMulti(handler, config);
}
