//! zix HTTP/3 URING dispatch: one SO_REUSEPORT worker per core, the kernel load-balancing connections
//! by 4-tuple (RC3 multicore). A dedicated io_uring submission path is a later phase (ADR-049 phase 2),
//! it shares this per-core worker shape.

const Config = @import("../config.zig");
const core = @import("../core.zig");
const common = @import("common.zig");

/// Run the HTTP/3 server with one SO_REUSEPORT worker per core.
pub fn runUring(comptime handler: core.HandlerFn, config: Config.Http3ServerConfig) !void {
    return common.runPerCore(handler, config);
}
