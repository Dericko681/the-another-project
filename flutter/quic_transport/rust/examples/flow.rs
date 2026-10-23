//! Full-flow probe: connect over QUIC, then exercise the same requests the
//! Flutter app makes, all on ONE connection (which is what exposed the
//! per-request h3-connection bug before).
//!
//!   cargo run --example flow

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

struct Client {
    h3: tokio::sync::Mutex<H3Client>,
    host: String,
}

struct H3Client {
    _driver: h3::client::Connection<h3_quinn::Connection, bytes::Bytes>,
    send_request: h3::client::SendRequest<h3_quinn::OpenStreams, bytes::Bytes>,
}

impl Client {
    async fn connect(addr: &str, host: &str) -> Result<Self, Box<dyn std::error::Error>> {
        let addr: std::net::SocketAddr = addr.parse()?;
        let mut crypto = rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(NoCertVerifier))
            .with_no_client_auth();
        crypto.alpn_protocols = vec![b"h3".to_vec()];
        let quic_config = quinn::crypto::rustls::QuicClientConfig::try_from(crypto)?;
        let mut endpoint = quinn::Endpoint::client("0.0.0.0:0".parse()?)?;
        endpoint.set_default_client_config(quinn::ClientConfig::new(Arc::new(quic_config)));
        let connection = endpoint.connect(addr, host)?.await?;

        let h3_conn = h3_quinn::Connection::new(connection);
        let (driver, send_request) = h3::client::new(h3_conn).await?;

        Ok(Client {
            h3: tokio::sync::Mutex::new(H3Client {
                _driver: driver,
                send_request,
            }),
            host: host.to_string(),
        })
    }

    async fn request(
        &self,
        method: &str,
        path: &str,
        body: Option<&str>,
    ) -> Result<(u16, String), Box<dyn std::error::Error>> {
        let uri = format!("https://{}{}", self.host, path).parse::<http::Uri>()?;
        let mut builder = http::Request::builder().method(method).uri(uri);
        // Force LITERAL encoding (not static index 46) by appending a param.
        builder = builder.header("content-type", "application/json");
        let request = builder.body(())?;

        let mut guard = self.h3.lock().await;
        println!("  [flow] locked, sending {method} {path}");
        let mut stream = guard.send_request.send_request(request).await?;
        drop(guard);
        println!("  [flow] sent, awaiting response");

        if let Some(b) = body {
            stream.send_data(bytes::Bytes::from(b.to_string())).await?;
        }
        // Always end the request stream so Caddy doesn't wait for a body.
        stream.finish().await?;

        let response = stream.recv_response().await?;
        let status = response.status().as_u16();
        let mut out = Vec::new();
        while let Some(mut chunk) = stream.recv_data().await? {
            out.extend_from_slice(chunk.chunk());
            chunk.advance(chunk.remaining());
        }
        Ok((status, String::from_utf8_lossy(&out).to_string()))
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let c = Client::connect("127.0.0.1:3443", "localhost").await?;
    println!("connected over QUIC");

    let (s1, b1) = c.request("GET", "/health", None).await?;
    println!("GET /health      -> {s1} {b1}");

    let (s2, b2) = c.request("GET", "/sessions?limit=1", None).await?;
    println!("GET /sessions    -> {s2} {b2}");

    let (s3, b3) = c.request("GET", "/models", None).await?;
    println!("GET /models      -> {s3} {b3}");

    let (s4, b4) = c.request("GET", "/agents", None).await?;
    println!("GET /agents      -> {s4} {b4}");

    let (s5, b5) = c.request(
        "POST",
        "/sessions",
        Some(r#"{"title":"quic-flow-test"}"#),
    )
    .await?;
    println!("POST /sessions   -> {s5} {b5}");

    Ok(())
}
