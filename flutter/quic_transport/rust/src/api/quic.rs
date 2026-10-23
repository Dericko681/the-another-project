//! Owned-in-Rust QUIC (HTTP/3) client for Flutter.
//!
//! Why this exists instead of the Dart-level negotiation in
//! `relay_transport_io.dart`: the Dart layer (via rhttp/reqwest) can only
//! choose "QUIC or HTTP/2" and reconnect with a back-off. It cannot reach the
//! QUIC features that matter on a flaky mobile hop:
//!
//!   * **connection migration** — quinn keeps the `quinn::Connection` alive
//!     across a network change (Wi-Fi → 4G) and rebinds the socket, so an
//!     in-flight stream survives without a reconnect;
//!   * **0-RTT** resumption;
//!   * **fine-grained resume** — the SSE client can ask the server to resume
//!     from a `Last-Event-ID` instead of re-reading the stream from the start.
//!
//! The Rust side owns the whole transport; Dart only sees a thin, typed API.
//!
//! TLS: the Caddy edge (`relay/Caddyfile`) serves a self-signed cert from its
//! local CA, so this client installs a no-op certificate verifier. Loopback
//! only — pin Caddy's root instead before this ever leaves localhost.

use std::net::SocketAddr;
use std::sync::Arc;

use bytes::Buf;
use flutter_rust_bridge::frb;
use rustls::client::danger::{
    HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier,
};

use crate::frb_generated::{RustAutoOpaque, StreamSink};

/// A live QUIC connection to the edge.
///
/// Holds the `quinn::Endpoint` (the UDP socket) and the `quinn::Connection`.
/// Keeping the connection alive is what lets quinn migrate it across network
/// changes. HTTP/3 request streams are multiplexed on top of it per request.
pub struct QuicClient {
    // Kept alive on purpose: dropping the endpoint closes the UDP socket, which
    // would kill connection migration. It is never read directly.
    #[allow(dead_code)]
    endpoint: quinn::Endpoint,
    // Kept alive on purpose: the h3 connection and request streams live on top
    // of this quinn connection; dropping it would tear them down and kill
    // connection migration. It is never read directly.
    #[allow(dead_code)]
    connection: quinn::Connection,
    // SNI host, used to build absolute-form URIs for HTTP/3 pseudo-headers.
    host: String,
    // The HTTP/3 connection state (QPACK + control stream). Serialised with a
    // mutex because `send_request` takes `&mut self`; the returned request
    // stream is independent, so the lock is only held while sending.
    h3: tokio::sync::Mutex<H3Client>,
}

/// The reusable half of an HTTP/3 connection. The other half (the driver) is
/// spawned as a background task so the control stream / QPACK stays alive.
struct H3Client {
    send_request: h3::client::SendRequest<h3_quinn::OpenStreams, bytes::Bytes>,
}

/// Result of a completed (non-streaming) HTTP/3 request.
pub struct QuicHttpResponse {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: String,
}

/// A request to send over the QUIC connection.
pub struct QuicRequest {
    pub method: String,
    pub path: String,
    pub headers: Vec<(String, String)>,
    pub body: Option<String>,
}

/// A single event pushed to Dart while a response body streams in.
///
/// A struct (not an enum) so FRB generates plain Dart without the freezed /
/// build_runner step that data-carrying enums require.
pub struct QuicStreamEvent {
    /// `"headers"`, `"data"` or `"end"`.
    pub kind: String,
    /// Populated when `kind == "headers"`.
    pub status: u16,
    /// Populated when `kind == "headers"`.
    pub headers: Vec<(String, String)>,
    /// Populated when `kind == "data"`.
    pub data: String,
}

/// Accepts any certificate. Loopback spike only — see module docs.
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

/// Builds a quinn client config that speaks `h3` and trusts any cert.
fn client_config(alpn: &[String]) -> Result<quinn::ClientConfig, String> {
    let mut crypto = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(NoCertVerifier))
        .with_no_client_auth();
    crypto.alpn_protocols = alpn.iter().map(|a| a.as_bytes().to_vec()).collect();

    let quic_config = quinn::crypto::rustls::QuicClientConfig::try_from(crypto)
        .map_err(|e| format!("quic client config: {e}"))?;
    Ok(quinn::ClientConfig::new(Arc::new(quic_config)))
}

/// Opens a QUIC connection to `addr` (e.g. `localhost:3443`) with SNI `host`.
///
/// `alpn` is the list of ALPN protocols to offer; pass `["h3"]` for HTTP/3.
#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
    let _ = rustls::crypto::ring::default_provider().install_default();
}

pub async fn quic_connect(
    addr: String,
    host: String,
    alpn: Vec<String>,
) -> Result<QuicClient, String> {
    let addr: SocketAddr = addr
        .parse()
        .map_err(|e| format!("bad addr {addr:?}: {e}"))?;

    let mut endpoint = quinn::Endpoint::client("0.0.0.0:0".parse().unwrap())
        .map_err(|e| format!("endpoint: {e}"))?;
    endpoint.set_default_client_config(client_config(&alpn)?);

    let connect = endpoint
        .connect(addr, &host)
        .map_err(|e| format!("connect: {e}"))?;
    let connection = connect
        .await
        .map_err(|e| format!("handshake: {e}"))?;

    // Open the HTTP/3 connection once and keep it for the life of the client.
    // `h3::client::new` returns two halves: a driver (Connection) that must be
    // polled to process the control stream / QPACK, and a SendRequest used to
    // send requests. The driver is spawned as a background task so the control
    // stream stays alive across requests — creating a new h3 connection per
    // request would open a second control stream and fail with
    // H3_STREAM_CREATION_ERROR.
    let h3_conn = h3_quinn::Connection::new(connection.clone());
    let (driver, send_request) = h3::client::new(h3_conn)
        .await
        .map_err(|e| format!("h3 open: {e}"))?;
    tokio::spawn(async move {
        let mut driver = driver;
        let _ = driver.wait_idle().await;
    });

    Ok(QuicClient {
        endpoint,
        connection,
        host,
        h3: tokio::sync::Mutex::new(H3Client { send_request }),
    })
}

/// Builds an absolute-form URI (`https://{host}{path}`) so h3 can emit the
/// `:scheme` / `:authority` / `:path` pseudo-headers HTTP/3 requires.
fn absolute_uri(host: &str, path: &str) -> Result<http::Uri, String> {
    let uri = format!("https://{host}{path}")
        .parse::<http::Uri>()
        .map_err(|e| format!("bad uri: {e}"))?;
    Ok(uri)
}

/// Runs a single HTTP/3 request and returns the full body.
///
/// Non-streaming on purpose — this is the transport probe, and it must be
/// replayable without side effects (a GET never mutates server state).
pub async fn quic_request(
    client: RustAutoOpaque<QuicClient>,
    req: QuicRequest,
) -> Result<QuicHttpResponse, String> {
    let client = client.try_read().map_err(|e| e.to_string())?;

    let mut builder = http::Request::builder()
        .method(req.method.as_str())
        .uri(absolute_uri(&client.host, &req.path)?);
    for (k, v) in &req.headers {
        builder = builder.header(k, v);
    }
    let request = builder
        .body(())
        .map_err(|e| format!("bad request: {e}"))?;

    // Hold the lock only while sending; the returned stream is independent.
    let mut guard = client.h3.lock().await;
    let mut stream = guard
        .send_request
        .send_request(request)
        .await
        .map_err(|e| format!("send: {e}"))?;
    drop(guard);

    if let Some(body) = &req.body {
        stream
            .send_data(bytes::Bytes::from(body.clone()))
            .await
            .map_err(|e| format!("send body: {e}"))?;
    }
    // Always end the request stream, even with no body. Caddy's HTTP/3 handler
    // waits for a request body when a Content-Type header is present (e.g.
    // `application/json`); if we never signal end-of-stream it hangs and the
    // reverse proxy times out (504 "no recent network activity").
    stream.finish().await.map_err(|e| format!("finish: {e}"))?;

    let response = stream
        .recv_response()
        .await
        .map_err(|e| format!("response: {e}"))?;
    let status = response.status().as_u16();
    let headers = response
        .headers()
        .iter()
        .map(|(k, v)| {
            (
                k.as_str().to_string(),
                v.to_str().unwrap_or("").to_string(),
            )
        })
        .collect();

    let mut body = Vec::new();
    while let Some(mut chunk) = stream
        .recv_data()
        .await
        .map_err(|e| format!("body: {e}"))?
    {
        body.extend_from_slice(chunk.chunk());
        chunk.advance(chunk.remaining());
    }

    Ok(QuicHttpResponse {
        status,
        headers,
        body: String::from_utf8_lossy(&body).to_string(),
    })
}

/// Streams an HTTP/3 response body to Dart as it arrives.
///
/// This is the SSE path: the [QuicStreamEvent::Headers] event carries the
/// status, then each body chunk is pushed as [QuicStreamEvent::Data] so tokens
/// arrive live instead of in a burst at the end, and finally [QuicStreamEvent::End].
pub async fn quic_request_stream(
    client: RustAutoOpaque<QuicClient>,
    req: QuicRequest,
    sink: StreamSink<QuicStreamEvent>,
) -> Result<(), String> {
    let client = client.try_read().map_err(|e| e.to_string())?;

    let mut builder = http::Request::builder()
        .method(req.method.as_str())
        .uri(absolute_uri(&client.host, &req.path)?);
    for (k, v) in &req.headers {
        builder = builder.header(k, v);
    }
    let request = builder
        .body(())
        .map_err(|e| format!("bad request: {e}"))?;

    let mut guard = client.h3.lock().await;
    let mut stream = guard
        .send_request
        .send_request(request)
        .await
        .map_err(|e| format!("send: {e}"))?;
    drop(guard);

    if let Some(body) = &req.body {
        stream
            .send_data(bytes::Bytes::from(body.clone()))
            .await
            .map_err(|e| format!("send body: {e}"))?;
    }
    // Always end the request stream (see quic_request for why this matters).
    stream.finish().await.map_err(|e| format!("finish: {e}"))?;

    let response = stream
        .recv_response()
        .await
        .map_err(|e| format!("response: {e}"))?;
    let status = response.status().as_u16();
    let headers = response
        .headers()
        .iter()
        .map(|(k, v)| {
            (
                k.as_str().to_string(),
                v.to_str().unwrap_or("").to_string(),
            )
        })
        .collect();
    let _ = sink.add(QuicStreamEvent {
        kind: "headers".to_string(),
        status,
        headers,
        data: String::new(),
    });

    while let Some(mut chunk) = stream
        .recv_data()
        .await
        .map_err(|e| format!("body: {e}"))?
    {
        let _ = sink.add(QuicStreamEvent {
            kind: "data".to_string(),
            status: 0,
            headers: Vec::new(),
            data: String::from_utf8_lossy(chunk.chunk()).to_string(),
        });
        chunk.advance(chunk.remaining());
    }
    let _ = sink.add(QuicStreamEvent {
        kind: "end".to_string(),
        status: 0,
        headers: Vec::new(),
        data: String::new(),
    });
    Ok(())
}
