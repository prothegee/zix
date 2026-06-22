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
pub const alertForError = connection.alertForError;
pub const alertRecordForError = connection.alertRecordForError;

/// The client-side handshakes (the mirror of the server). zix.Tls.Client = TLS 1.3,
/// zix.Tls.Client12 = TLS 1.2. Each exposes start / finish + a ClientConnection (sans-I/O).
pub const Client = @import("client.zig");
pub const Client12 = @import("tls12_client.zig");

/// Layer V: peer certificate verification (the trust step of mTLS).
/// verifyCertChain = chain + validity (RFC 5280). verifyCertHostname = identity (RFC 6125).
pub const verifyCertChain = @import("cert_verify.zig").verifyCertChain;
pub const verifyCertHostname = @import("cert_verify.zig").verifyCertHostname;

pub const Alpn = extensions.Alpn;
pub const Alert = alert.Alert;
pub const fatal_record_len = alert.fatal_record_len;
pub const ContentType = record.ContentType;
pub const CipherSuite = handshake.CipherSuite;
pub const NamedGroup = handshake.NamedGroup;
