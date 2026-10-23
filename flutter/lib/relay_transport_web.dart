/// Web transport — the browser owns the network stack.
///
/// A browser already speaks HTTP/2 and HTTP/3 when the origin offers them via
/// ALPN / `Alt-Svc`, and it does so without any Dart help. But the desktop app
/// talks to a *plaintext loopback* relay on the web target, and neither QUIC
/// nor HTTP/2 applies to a cleartext localhost origin, so nothing here changes.
///
/// `FetchClient` rather than `dart:io` because the browser's Fetch API is the
/// only way to stream a response body — an SSE feed never delivers a byte
/// through XHR, which is what the plain `http` package uses on web.
library;

import 'package:fetch_client/fetch_client.dart';
import 'package:http/http.dart' as http;

import 'relay_transport_base.dart';

class _BrowserTransport implements RelayTransport {
  final http.Client _raw;

  _BrowserTransport(this._raw);

  @override
  http.Client get client => _raw;

  @override
  String get label => 'HTTP/1.1 (browser Fetch)';

  @override
  bool get isFallback => false;

  @override
  Future<void> close() async => _raw.close();
}

Future<RelayTransport> createRelayTransport(Uri base) async =>
    _BrowserTransport(FetchClient(mode: RequestMode.cors));
