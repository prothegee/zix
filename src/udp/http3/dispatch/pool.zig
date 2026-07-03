//! zix HTTP/3 POOL dispatch (ADR-050): multi-core, one SO_REUSEPORT recvmmsg worker per CPU, each owning
//! its own CID table (the kernel load-balances connections by 4-tuple).

const Config = @import("../config.zig");
const core = @import("../core.zig");
const common = @import("common.zig");

/// Run the HTTP/3 server with one SO_REUSEPORT recvmmsg worker per CPU (multi-core).
pub fn runPool(comptime handler: core.HandlerFn, config: Config.Http3ServerConfig) !void {
    return common.runMulti(handler, config);
}
