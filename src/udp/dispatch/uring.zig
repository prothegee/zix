//! zix udp raw-bytes URING dispatch (ADR-049): per-core SO_REUSEPORT workers. A dedicated io_uring
//! submission path is a later phase, so URING currently folds to the recvmmsg per-core loop.

const Config = @import("../config.zig");
const core = @import("../core.zig");
const common = @import("common.zig");

/// Run the raw server with per-core SO_REUSEPORT workers (recvmmsg loop, the URING fold).
pub fn runUring(comptime handler: core.HandlerFn, config: Config.UdpServerConfig) !void {
    common.logSystem(config, "URING folds to the recvmmsg per-core loop (ADR-049 phase 1)", .{});

    return common.runPerCore(handler, config);
}
