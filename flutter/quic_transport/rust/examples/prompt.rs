//! Full app-flow probe over QUIC: create a session, send a prompt, and stream
//! the SSE /stream response — the exact path that makes the model "respond".
//!
//!   cargo run --example prompt

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
        builder = builder.header("content-type", "application/json");
        builder = builder.header("accept", "application/json");
        let request = builder.body(())?;
        let mut guard = self.h3.lock().await;
        let mut stream = guard.send_request.send_request(request).await?;
        drop(guard);
        if let Some(b) = body {
            stream.send_data(bytes::Bytes::from(b.to_string())).await?;
        }
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

    // 1. Create a session with the default model (no explicit model).
    let (s1, b1) = c
        .request("POST", "/sessions", Some(r#"{"title":"quic-prompt-test"}"#))
        .await?;
    println!("POST /sessions -> {s1} {b1}");
    let session_id = extract_session_id(&b1);

    // 2. Send a prompt into it.
    let (s2, b2) = c
        .request(
            "POST",
            &format!("/sessions/{session_id}/prompt"),
            Some(r#"{"prompt":"Say hello in one short sentence"}"#),
        )
        .await?;
    println!("POST prompt    -> {s2} {b2}");

    // 3. Stream /stream for a few seconds to catch the SSE tokens.
    println!("--- streaming /stream over QUIC ---");
    let uri = "https://localhost/stream".parse::<http::Uri>()?;
    let mut builder = http::Request::builder().method("GET").uri(uri);
    builder = builder.header("accept", "text/event-stream");
    builder = builder.header("cache-control", "no-cache");
    let request = builder.body(())?;
    let mut guard = c.h3.lock().await;
    let mut stream = guard.send_request.send_request(request).await?;
    drop(guard);
    stream.finish().await?;
    let response = stream.recv_response().await?;
    println!("stream status: {}", response.status());
    let mut count = 0;
    let mut text = String::new();
    let mut types = std::collections::HashMap::<String, usize>::new();
    // Read for up to ~75s or until we see text deltas.
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(75);
    while tokio::time::Instant::now() < deadline {
        match tokio::time::timeout(std::time::Duration::from_secs(5), stream.recv_data()).await {
            Ok(Ok(Some(mut chunk))) => {
                let s = String::from_utf8_lossy(chunk.chunk()).to_string();
                text.push_str(&s);
                // Count event types by looking for `"type":"..."`.
                for line in s.lines() {
                    if let Some(t) = line.split("\"type\":\"").nth(1).and_then(|x| x.split('"').next()) {
                        *types.entry(t.to_string()).or_insert(0) += 1;
                    }
                }
                if s.contains("session.text.delta") {
                    count += 1;
                }
                chunk.advance(chunk.remaining());
            }
            Ok(Ok(None)) => break,
            Ok(Err(e)) => {
                println!("stream error: {e}");
                break;
            }
            Err(_) => {
                if count > 0 {
                    break;
                }
            }
        }
    }
    println!("text.delta events seen: {count}");
    println!("event type counts: {:?}", types);
    println!("FULL STREAM:\n{}", text);
    Ok(())
}

fn extract_session_id(body: &str) -> String {
    // {"session":{"id":"ses_...",...}}
    let key = "\"id\":\"";
    if let Some(pos) = body.find(key) {
        let rest = &body[pos + key.len()..];
        if let Some(end) = rest.find('"') {
            return rest[..end].to_string();
        }
    }
    String::new()
}
