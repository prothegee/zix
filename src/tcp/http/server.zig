const std = @import("std");

//
// NOTE:
// - The new IO since zig 0.16 Threaded is use limited and unlimited request
//   assume the number from 1-8192 for each thread,
//   then the overhead is depend on the each handler.
//   So create two engine instead rather than one,
//   one using minimal approach so full controll on the handler implementation
//   two using default approach which has some overhead specially on middlewares usage.
//

// /// zix tcp http server config structure
// pub const Config = struct {
//     // ?listener
//     // ?static_dir
//     // ?static_dir_upload
// };

// zix tcp http server engine structure
pub const Engine = struct {
    // ?config:
    // ?[]listeners: [{
    //      ipv4: string
    //      ipv6: string
    //      port: u16
    //  }]
    // ?[]plugins
    // ?[]databases
    // ?[]handlers
    //
    // ?loadConfigJson("config.json")
};

// --------------------------------------------------------- //

// ?
