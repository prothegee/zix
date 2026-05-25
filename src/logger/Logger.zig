//! zix logger namespace

const logger = @import("logger.zig");

pub const Logger = logger.Logger;
pub const Level = Logger.Level;
pub const ConsoleMode = Logger.ConsoleMode;
pub const Dir = Logger.Dir;
pub const Config = Logger.Config;
