/// quic_transport — an owned-in-Rust QUIC (HTTP/3) client for Flutter.
///
/// The transport lives entirely in Rust (quinn + h3), exposed to Dart through
/// flutter_rust_bridge. Dart only sees a thin, typed API. This is the piece
/// that lets the app reach QUIC features the Dart layer cannot: connection
/// migration, 0-RTT and fine-grained resume.
///
/// [QuicHttpClient] adapts the Rust client to the `package:http` `BaseClient`
/// interface, so it can be dropped straight into the app's `RelayTransport`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'src/rust/api/quic.dart' as frb;
import 'src/rust/frb_generated.dart' as frb_gen;

/// Initialises the Rust runtime. Call once before any other function.
///
/// Safe to call multiple times; FRB guards its own init.
Future<void> init() => frb_gen.RustLib.init();

/// A live QUIC connection to an edge. Holds the Rust `QuicClient` opaque
/// handle; the underlying `quinn::Connection` stays alive for the lifetime of
/// this object, which is what lets quinn migrate it across network changes.
class QuicClient {
  final frb.QuicClient _inner;

  QuicClient._(this._inner);

  /// Opens a QUIC connection to `addr` (e.g. `localhost:3443`) with SNI `host`.
  ///
  /// `alpn` is the list of ALPN protocols to offer; pass `['h3']` for HTTP/3.
  static Future<QuicClient> connect({
    required String addr,
    required String host,
    List<String> alpn = const ['h3'],
  }) async {
    final inner = await frb.quicConnect(addr: addr, host: host, alpn: alpn);
    return QuicClient._(inner);
  }

  /// Runs a single HTTP/3 request and returns the full body.
  ///
  /// Non-streaming on purpose — this is the transport probe, and it must be
  /// replayable without side effects (a GET never mutates server state).
  Future<QuicHttpResponse> request(
    String method,
    String path, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final res = await frb.quicRequest(
      client: _inner,
      req: frb.QuicRequest(
        method: method,
        path: path,
        headers: headers.entries.map((e) => (e.key, e.value)).toList(),
        body: body,
      ),
    );
    return QuicHttpResponse(
      status: res.status,
      headers: Map.fromEntries(res.headers.map((h) => MapEntry(h.$1, h.$2))),
      body: res.body,
    );
  }

  /// Streams an HTTP/3 response body as it arrives.
  ///
  /// This is the SSE path: the first event carries the status, then each body
  /// chunk arrives live, and finally an end marker.
  Stream<frb.QuicStreamEvent> streamRequest(
    String method,
    String path, {
    Map<String, String> headers = const {},
    String? body,
  }) =>
      frb.quicRequestStream(
        client: _inner,
        req: frb.QuicRequest(
          method: method,
          path: path,
          headers: headers.entries.map((e) => (e.key, e.value)).toList(),
          body: body,
        ),
      );

  /// An `http.Client` view over this QUIC connection.
  http.Client get httpClient => QuicHttpClient(this);
}

/// Result of a completed (non-streaming) HTTP/3 request.
class QuicHttpResponse {
  final int status;
  final Map<String, String> headers;
  final String body;

  const QuicHttpResponse({
    required this.status,
    required this.headers,
    required this.body,
  });

  bool get isOk => status >= 200 && status < 300;
}

/// Adapts a [QuicClient] to `package:http`'s [http.BaseClient].
///
/// Every request goes through the streaming path so that long-lived SSE
/// responses deliver their body live; short responses simply complete quickly.
class QuicHttpClient extends http.BaseClient {
  final QuicClient _client;

  QuicHttpClient(this._client);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bodyBytes = await request.finalize().toBytes();
    final path = request.url.path +
        (request.url.hasQuery ? '?${request.url.query}' : '');

    final events = _client.streamRequest(
      request.method,
      path,
      headers: request.headers,
      body: bodyBytes.isEmpty ? null : utf8.decode(bodyBytes),
    );

    final bodyController = StreamController<List<int>>();
    final responseCompleter = Completer<http.StreamedResponse>();

    late final StreamSubscription<frb.QuicStreamEvent> sub;
    sub = events.listen(
      (event) {
        switch (event.kind) {
          case 'headers':
            final respHeaders = <String, String>{};
            for (final h in event.headers) {
              respHeaders[h.$1] = h.$2;
            }
            if (!responseCompleter.isCompleted) {
              responseCompleter.complete(http.StreamedResponse(
                bodyController.stream,
                event.status,
                headers: respHeaders,
                request: request,
              ));
            }
          case 'data':
            bodyController.add(utf8.encode(event.data));
          case 'end':
            if (!bodyController.isClosed) bodyController.close();
            sub.cancel();
        }
      },
      onError: (Object e) {
        if (!responseCompleter.isCompleted) {
          responseCompleter.completeError(e);
        }
        if (!bodyController.isClosed) {
          bodyController.addError(e);
          bodyController.close();
        }
      },
      onDone: () {
        if (!bodyController.isClosed) bodyController.close();
      },
    );

    return responseCompleter.future;
  }
}
