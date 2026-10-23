/// Shared contract for "how the app reaches the relay".
///
/// The concrete strategies live in [relay_transport_io.dart] (desktop/mobile:
/// QUIC first, HTTP/2 fallback) and [relay_transport_web.dart] (browser).
/// [relay_transport.dart] picks one at compile time, so nothing here — and
/// nothing in `opencode_client.dart` — needs to know which platform it is on.
library;

import 'package:http/http.dart' as http;

/// A negotiated connection strategy to the relay.
abstract class RelayTransport {
  /// The HTTP client every request and the SSE stream go through.
  http.Client get client;

  /// Human-readable protocol, e.g. `QUIC · HTTP/3`.
  String get label;

  /// True when the preferred protocol was unavailable and this is the fallback.
  bool get isFallback;

  /// Release sockets. Does not unload the native library.
  Future<void> close();
}

/// Thrown when no transport could be established at all.
class RelayTransportException implements Exception {
  final String message;

  const RelayTransportException(this.message);

  @override
  String toString() => message;
}
