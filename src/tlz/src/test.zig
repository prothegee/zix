//! TLZ unit and edge test
//!
//! ### file: src/tlz/src/test.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! TLZ unit and edge test entry: imports every source file so its tests run.
//!
//! ### note:
//!
//! A test root only collects tests from itself and files it imports by path.
//! Tests inside an imported module are skipped, so every file is imported here.
//!
//! ---------------------------------------------------------
//!
//! ### licenses:
//!
//! - BSD-3-Clause
//!
//! ### copyright:
//!
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//!
//! ### contributors:
//!
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test {
    _ = @import("lib.zig");

    _ = @import("wire/Reader.zig");
    _ = @import("wire/Writer.zig");
    _ = @import("alert.zig");
    _ = @import("alert/description.zig");
    _ = @import("alert/Inbound.zig");
    _ = @import("key_schedule.zig");
    _ = @import("key_schedule/Transcript.zig");
    _ = @import("record.zig");
    _ = @import("record/content_type.zig");
    _ = @import("record/Opened.zig");
    _ = @import("cipher_suite.zig");
    _ = @import("named_group.zig");
    _ = @import("signature_scheme.zig");
    _ = @import("extension_type.zig");
    _ = @import("alpn.zig");

    _ = @import("handshake.zig");
    _ = @import("handshake/handshake_type.zig");
    _ = @import("handshake/ClientHello.zig");
    _ = @import("handshake/ServerHelloParams.zig");
    _ = @import("extensions.zig");
    _ = @import("extensions/EncryptedExtensionsOptions.zig");
    _ = @import("connection.zig");
    _ = @import("connection/Connection.zig");
    _ = @import("connection/HandshakeOptions.zig");
    _ = @import("connection/HandshakeMessage.zig");
    _ = @import("connection/HandshakeResult.zig");
    _ = @import("connection/KeyExchange.zig");
    _ = @import("connection/RetryState.zig");
    _ = @import("connection/RetryFlight.zig");
    _ = @import("client.zig");
    _ = @import("client/HandshakeOptions.zig");
    _ = @import("client/State.zig");
    _ = @import("client/StartResult.zig");
    _ = @import("client/FinishResult.zig");
    _ = @import("client/ClientConnection.zig");
    _ = @import("client/ServerHelloParsed.zig");
    _ = @import("context.zig");
    _ = @import("context/Context.zig");
    _ = @import("context/Config.zig");
    _ = @import("context/version.zig");

    _ = @import("crypto/DerReader.zig");
    _ = @import("crypto/der_guard.zig");
    _ = @import("crypto/pem.zig");
    _ = @import("crypto/montgomery.zig");
    _ = @import("crypto/montgomery/asm_body.zig");
    _ = @import("crypto/std_rsa_verify.zig");
    _ = @import("crypto/rsa.zig");
    _ = @import("crypto/rsa/PrivateKey.zig");
    _ = @import("crypto/rsa/crt.zig");
    _ = @import("crypto/certificate.zig");
    _ = @import("crypto/certificate/signing_key.zig");
    _ = @import("crypto/cert_verify.zig");
    _ = @import("crypto/cert_verify/PathConstraints.zig");

    _ = @import("tls12/prf.zig");
    _ = @import("tls12/prf/KeyMaterial.zig");
    _ = @import("tls12/record.zig");
    _ = @import("tls12/version.zig");
    _ = @import("tls12/version/selected.zig");
    _ = @import("tls12/connection.zig");
    _ = @import("tls12/connection/HandshakeOptions.zig");
    _ = @import("tls12/connection/State.zig");
    _ = @import("tls12/connection/Flight1.zig");
    _ = @import("tls12/connection/FinishResult.zig");
    _ = @import("tls12/connection/Connection.zig");
    _ = @import("tls12/client.zig");
    _ = @import("tls12/client/HandshakeOptions.zig");
    _ = @import("tls12/client/State.zig");
    _ = @import("tls12/client/StartResult.zig");
    _ = @import("tls12/client/FinishResult.zig");
    _ = @import("tls12/client/ClientConnection.zig");
    _ = @import("tls12/client/ServerFlight.zig");
}

