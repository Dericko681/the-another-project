/// Compile-time transport selection.
///
/// `dart.library.js_interop` is only defined when compiling for the browser, so
/// a web build resolves [createRelayTransport] to the Fetch-based implementation
/// and never pulls in rhttp or any native code. A desktop build gets the
/// QUIC-first implementation from `relay_transport_io.dart`.
library;

export 'relay_transport_base.dart';
export 'relay_transport_io.dart'
    if (dart.library.js_interop) 'relay_transport_web.dart';
