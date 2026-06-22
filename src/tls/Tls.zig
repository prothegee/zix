//! zix tls namespace: TLS 1.3 server layer (RFC 8446).
//!
//! Sans-I/O: drive a handshake with `serverHandshake`, then read / write application records
//! through the returned `Connection`. The caller owns the socket loop. cleartext stays the
//! default, https is an opt-in path on its own perf band.

const connection = @import("connection.zig");
const extensions = @import("extensions.zig");
const handshake = @import("handshake.zig");
const record = @import("record.zig");
const alert = @import("alert.zig");

// --------------------------------------------------------------- //

pub const Connection = connection.Connection;
pub const HandshakeOptions = connection.HandshakeOptions;
pub const HandshakeResult = connection.HandshakeResult;
pub const serverHandshake = connection.serverHandshake;

pub const Alpn = extensions.Alpn;
pub const Alert = alert.Alert;
pub const ContentType = record.ContentType;
pub const CipherSuite = handshake.CipherSuite;
pub const NamedGroup = handshake.NamedGroup;
