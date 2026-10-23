//! Standalone probe: connect to the Caddy edge over QUIC and GET /health.
//!
//! Run with the edge up:
//!   cargo run --example probe
//!
//! Expects `{"relay":"ok",...}` and status 200.
//!
//! This duplicates the transport logic in `api/quic.rs` on purpose so the
//! example can run without the FRB opaque-handle plumbing.

use std::sync::Arc;

use bytes::Buf;
use rustls::client::danger::{
    HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier,
};

#[derive(Debug)]
struct NoCertVerifier;

impl ServerCertVerifier for NoCertVerifier {
    fn verify_server_cert(
        &self,
        _end_entity: &rustls::pki_types::CertificateDer<'_>,
        _intermediates: &[rustls::pki_types::CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp_response: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &rustls::pki_types::CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }
    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &rustls::pki_types::CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }
    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let addr: std::net::SocketAddr = "127.0.0.1:3443".parse()?;

    let mut crypto = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(NoCertVerifier))
        .with_no_client_auth();
    crypto.alpn_protocols = vec![b"h3".to_vec()];

    let quic_config = quinn::crypto::rustls::QuicClientConfig::try_from(crypto)?;
    let mut endpoint = quinn::Endpoint::client("0.0.0.0:0".parse()?)?;
    endpoint.set_default_client_config(quinn::ClientConfig::new(Arc::new(quic_config)));

    let connection = endpoint.connect(addr, "localhost")?.await?;
    println!("connected over QUIC");

    let h3_conn = h3_quinn::Connection::new(connection);
    let (_h3, mut send_request) = h3::client::new(h3_conn).await?;

    let request = http::Request::builder()
        .method("GET")
        .uri("https://localhost/health")
        .body(())?;
    let mut stream = send_request.send_request(request).await?;
    let response = stream.recv_response().await?;
    println!("status: {}", response.status());

    let mut body = Vec::new();
    while let Some(mut chunk) = stream.recv_data().await? {
        body.extend_from_slice(chunk.chunk());
        chunk.advance(chunk.remaining());
    }
    println!("body:   {}", String::from_utf8_lossy(&body));
    Ok(())
}
