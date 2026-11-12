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

    _ = @import("dtls/cookie.zig");
    _ = @import("dtls/cookie/Signer.zig");
    _ = @import("dtls/record.zig");
    _ = @import("dtls/record/Header.zig");
    _ = @import("dtls/record/Opened.zig");
    _ = @import("dtls/record/RecordIterator.zig");
    _ = @import("dtls/record/AntiReplay.zig");
    _ = @import("dtls/handshake.zig");
    _ = @import("dtls/handshake/message_type.zig");
    _ = @import("dtls/handshake/Header.zig");
    _ = @import("dtls/handshake/Fragment.zig");
    _ = @import("dtls/handshake/FragmentIterator.zig");
    _ = @import("dtls/handshake/Fragmenter.zig");
    _ = @import("dtls/handshake/reassembler.zig");
    _ = @import("dtls/hello.zig");
    _ = @import("dtls/hello/ClientHello.zig");
    _ = @import("dtls/flight.zig");
    _ = @import("dtls/flight/state.zig");
    _ = @import("dtls/flight/timeout_action.zig");
    _ = @import("dtls/flight/Timer.zig");
    _ = @import("dtls/flight/Flight.zig");
    _ = @import("dtls/exporter.zig");
    _ = @import("dtls/exporter/srtp_profile.zig");
    _ = @import("dtls/exporter/SrtpKeys.zig");
    _ = @import("dtls/use_srtp.zig");
    _ = @import("dtls/use_srtp/Offered.zig");
    _ = @import("dtls/connection.zig");
    _ = @import("dtls/connection/HandshakeOptions.zig");
    _ = @import("dtls/connection/State.zig");
    _ = @import("dtls/connection/Flight.zig");
    _ = @import("dtls/connection/FinishResult.zig");
    _ = @import("dtls/connection/Connection.zig");
    _ = @import("dtls/client.zig");
    _ = @import("dtls/client/Options.zig");
    _ = @import("dtls/client/ServerFlight.zig");
    _ = @import("dtls/client/State.zig");
    _ = @import("dtls/client/ClientConnection.zig");
    _ = @import("dtls/client/FinishResult.zig");
}

