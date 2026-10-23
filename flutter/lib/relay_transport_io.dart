/// Desktop/mobile transport — **QUIC (HTTP/3) first, HTTP/2 as fallback**.
///
/// Why the fallback is hand-rolled: rhttp maps `HttpVersionPref.http3` onto
/// reqwest's `http3_prior_knowledge()`, which means "speak QUIC or fail" — it
/// does not negotiate down on its own (reqwest only downgrades via Alt-Svc
/// discovery, which it does not implement). So the negotiation lives here:
///
///   1. probe `GET /health` over HTTP/3 (UDP) with a throwaway client;
///   2. if that fails, probe over HTTP/2 (TCP) the same way;
///   3. if both fail, report it instead of silently degrading to HTTP/1.1.
///
/// The probe is a GET, so retrying it against a different transport can never
/// duplicate a side effect — unlike replaying a prompt.
///
/// Three subtleties worth keeping:
///
/// * **Probe and stream need different timeouts.** A stalled QUIC handshake
///   must fail fast, so the probe client gets a *total* request timeout. The
///   long-lived client must not, or the SSE stream would be cut off mid-turn.
/// * **The probe must not use the `http`-compatible client.** `BaseClient.get`
///   funnels through `send()` → rhttp's *streaming* request, which is the only
///   path that registers Dart callbacks (`on_response`/`on_error`). When such a
///   request fails, rhttp re-enters Dart through that callback and
///   flutter_rust_bridge's DartFn handler panics — with `panic = "abort"` in
///   rhttp's Rust profile that kills the whole process, not just the request.
///   The probe therefore calls the non-streaming `RhttpClient.getText`, which
///   only registers `on_cancel_token` (and only when a `CancelToken` is given,
///   so with no token nothing is registered at all). Failures then surface as a
///   plain Dart future error.
/// * **Never abandon an in-flight request and then dispose the client.** A Dart
///   `Future.timeout` on a request rhttp is still running cancels it from under
///   the Rust side; let *rhttp* end the request (via its own timeouts) and only
///   then dispose.
library;

import 'dart:async';
import 'dart:io' show InternetAddress;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:quic_transport/quic_transport.dart' as qt;
import 'package:rhttp/rhttp.dart' as rhttp;

import 'relay_transport_base.dart';

/// Escape hatch for testing the paths individually:
///   flutter run -d linux --dart-define=TRANSPORT_FORCE=quic
///   flutter run -d linux --dart-define=TRANSPORT_FORCE=h2
/// Empty (the default) means "try QUIC, fall back to HTTP/2".
const String _forced = String.fromEnvironment('TRANSPORT_FORCE');

/// The edge serves a self-signed certificate (Caddy `tls internal` — see
/// `relay/Caddyfile`). Only ever used on loopback; nothing here is exposed.
const rhttp.TlsSettings _tls = rhttp.TlsSettings(verifyCertificates: false);

/// Throwaway probe client: bounded in total, so a blocked UDP path gives up
/// instead of hanging the app's first request forever.
const rhttp.TimeoutSettings _probeTimeouts = rhttp.TimeoutSettings(
  connectTimeout: Duration(seconds: 2),
  timeout: Duration(seconds: 3),
);

/// Long-lived client: a connect budget but **no total timeout**, because the
/// `/stream` response is an SSE feed that stays open for the whole turn.
const rhttp.TimeoutSettings _streamTimeouts = rhttp.TimeoutSettings(
  connectTimeout: Duration(seconds: 2),
);

bool _rustReady = false;

/// Loads the Rust libraries once. Guarded because both rhttp and the
/// quic_transport plugin's init are not idempotent-safe across hot restarts.
Future<void> _ensureRust() async {
  if (_rustReady) return;
  await rhttp.Rhttp.init();
  await qt.init();
  _rustReady = true;
}

class _RhttpTransport implements RelayTransport {
  final rhttp.RhttpCompatibleClient _raw;

  @override
  final String label;

  @override
  final bool isFallback;

  _RhttpTransport(this._raw, this.label, this.isFallback);

  @override
  http.Client get client => _raw;

  /// Frees the Rust client **without** cancelling in-flight requests.
  ///
  /// `RhttpCompatibleClient.close()` would call
  /// `dispose(cancelRunningRequests: true)`, and that is the one thing that can
  /// kill the process. Cancelling fires the client's cancel token, which makes
  /// rhttp's `select!` in `make_http_request_receive_stream` abandon the branch
  /// that is still `await`ing a Dart callback (`on_response`/`on_error`). When
  /// Dart's reply then arrives there is no receiver left, and
  /// flutter_rust_bridge's `handle_output` does `completer.send(msg).unwrap()` —
  /// a panic, and rhttp builds with `panic = "abort"`, so the app dies instead
  /// of just the request. Letting rhttp end its own requests avoids that
  /// entirely; on teardown we lose nothing by not cancelling.
  @override
  Future<void> close() async => _raw.client.dispose();
}

class _PlainHttpTransport implements RelayTransport {
  final http.Client _raw;
  final String _label;

  _PlainHttpTransport(this._raw, this._label);

  @override
  http.Client get client => _raw;

  @override
  String get label => _label;

  @override
  bool get isFallback => false;

  @override
  Future<void> close() async => _raw.close();
}

/// Builds the `http`-compatible client the app uses for requests and SSE.
Future<rhttp.RhttpCompatibleClient> _client(
  rhttp.HttpVersionPref pref,
  rhttp.TimeoutSettings timeouts,
) =>
    rhttp.RhttpCompatibleClient.create(
      settings: rhttp.ClientSettings(
        httpVersionPref: pref,
        tlsSettings: _tls,
        timeoutSettings: timeouts,
      ),
    );

/// `GET /health` over [pref]. Returns null on success, else why it failed.
///
/// Deliberately uses the raw [rhttp.RhttpClient] (non-streaming `getText`), not
/// the `http`-compatible client — see the library doc comment for why the
/// DartFn-based streaming path is unsafe for a failure probe.
///
/// The client is disposed in [finally]: by then rhttp has finished the request
/// (either answered or timed out), so there is nothing in flight to cancel.
Future<String?> _probe(Uri base, rhttp.HttpVersionPref pref) async {
  final client = await rhttp.RhttpClient.create(
    settings: rhttp.ClientSettings(
      httpVersionPref: pref,
      tlsSettings: _tls,
      timeoutSettings: _probeTimeouts,
    ),
  );
  try {
    final res = await client.getText(base.resolve('/health').toString());
    if (res.statusCode >= 200 && res.statusCode < 300) return null;
    return 'HTTP ${res.statusCode}';
  } catch (e) {
    return e.toString();
  } finally {
    client.dispose();
  }
}

/// Opens the client the app will actually use for [pref].
Future<RelayTransport> _open(
  rhttp.HttpVersionPref pref,
  String label,
  bool fallback,
) async =>
    _RhttpTransport(await _client(pref, _streamTimeouts), label, fallback);

/// Transport backed by the owned-in-Rust QUIC client (quinn + h3).
class _QuicTransport implements RelayTransport {
  final qt.QuicClient _quic;

  _QuicTransport(this._quic);

  @override
  http.Client get client => _quic.httpClient;

  @override
  String get label => 'QUIC · HTTP/3 (Rust)';

  @override
  bool get isFallback => false;

  @override
  Future<void> close() async {}
}

/// Probes `GET /health` over QUIC using the owned-in-Rust client.
///
/// Returns null on success, else why it failed. Resolves the host to an IP
/// because quinn connects to a `SocketAddr` (reqwest resolved DNS for us).
Future<String?> _probeQuic(Uri base) async {
  try {
    final host = base.host;
    final addr = (await InternetAddress.lookup(host)).first.address;
    final client = await qt.QuicClient.connect(
      addr: '$addr:${base.port}',
      host: host,
    );
    final res = await client.request('GET', '/health');
    return res.isOk ? null : 'HTTP ${res.status}';
  } catch (e) {
    return e.toString();
  }
}

/// Builds the transport for [base] (e.g. `https://localhost:3443`).
Future<RelayTransport> createRelayTransport(Uri base) async {
  // Plaintext cannot carry QUIC, and `http://` is only used by the web target
  // and by `--dart-define=RELAY_URL=http://...` debugging.
  if (base.scheme != 'https') {
    return _PlainHttpTransport(
      http.Client(),
      'HTTP/1.1 (plaintext — no TLS, so no QUIC)',
    );
  }

  await _ensureRust();
  final failures = <String>[];

  if (_forced != 'h2') {
    final h3Error = await _probeQuic(base);
    if (h3Error == null) {
      debugPrint('[transport] QUIC up — $base answers on HTTP/3 (UDP)');
      final quic = await qt.QuicClient.connect(
        addr: '${(await InternetAddress.lookup(base.host)).first.address}:${base.port}',
        host: base.host,
      );
      return _QuicTransport(quic);
    }
    debugPrint('[transport] QUIC unavailable ($h3Error) — trying HTTP/2');
    failures.add('HTTP/3 (QUIC): $h3Error');
  }

  final h2Error = await _probe(base, rhttp.HttpVersionPref.http2);
  if (h2Error == null) {
    debugPrint('[transport] HTTP/2 up — falling back on $base (TCP)');
    return _open(
      rhttp.HttpVersionPref.http2,
      'HTTP/2 (fallback)',
      _forced == 'h2' || failures.isNotEmpty,
    );
  }
  failures.add('HTTP/2: $h2Error');
  debugPrint('[transport] no usable transport: ${failures.join('; ')}');

  throw RelayTransportException(
    'No usable transport for $base.\n'
    '${failures.join('\n')}\n'
    'Start the TLS edge (./scripts/edge.sh) — it terminates QUIC on UDP '
    '${base.port} and HTTP/2 on TCP ${base.port}.',
  );
}
