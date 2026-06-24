//! zix udp raw-bytes EPOLL dispatch (ADR-049): one SO_REUSEPORT recvmmsg worker per CPU.

const Config = @import("../config.zig");
const core = @import("../core.zig");
const common = @import("common.zig");

/// Run the raw server with per-core SO_REUSEPORT workers.
pub fn runEpoll(comptime handler: core.HandlerFn, config: Config.UdpServerConfig) !void {
    return common.runPerCore(handler, config);
}
