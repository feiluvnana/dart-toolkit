import 'dart:async';

import 'package:http/http.dart' as http;

const _clientKey = #dartToolkitHttpClient;

/// The ambient HTTP client seam.
///
/// Every entry point in this module takes an optional `client:`. A session sets one
/// for all of them at once, so a script reuses connections without threading a client
/// through every call.
///
/// {@category Networking}
class Http {
  /// The client of the enclosing [session], or `null` outside one.
  static http.Client? get client => Zone.current[_clientKey] as http.Client?;

  /// Runs [body] with one shared client for every HTTP call inside it.
  ///
  /// The client is closed when [body] completes, unless [client] was supplied — an
  /// open client delays process exit until its idle connections time out.
  static Future<T> session<T>(FutureOr<T> Function() body, {http.Client? client}) async {
    final shared = client ?? http.Client();
    try {
      return await runZoned(() async => body(), zoneValues: {_clientKey: shared});
    } finally {
      if (client == null) shared.close();
    }
  }
}

/// A borrowed or owned client. Internal: hidden by `http/http.dart`.
class ClientLease {
  final http.Client client;
  final bool _owned;

  const ClientLease(this.client, this._owned);

  /// Closes the client only if this lease created it.
  void close() {
    if (_owned) client.close();
  }
}

/// Resolves the client for one call: the explicit one, else the session's, else a new one.
ClientLease clientFor(http.Client? explicit) {
  final shared = explicit ?? Http.client;
  return shared != null ? ClientLease(shared, false) : ClientLease(http.Client(), true);
}
