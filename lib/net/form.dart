/// # Sending a Form
///
/// The other half of [Form]. Reading a `<form>` — its action, its method, the
/// values its controls would submit — is HTML, and lives behind
/// `markup.form(...)`. Sending one is a socket, and lives here.
///
/// The domain that owns the *verb* declares the extension, on the type the
/// domain that owns the *noun* holds. Through 5.5.0 both halves were in `net`,
/// walking a parsed DOM in the domain whose own doc says it parses nothing.
/// {@category Networking}
library;

import 'dart:async';

import '../format/format.dart';
import '../src/format.dart';
import '../src/markup.dart';
import 'net.dart';

// ============================================================================
// SENDING A FORM
// ============================================================================

/// Submitting a [Form].
extension Sending on Form {
  /// The request this form would send.
  ///
  /// Everything comes off the form — the method, the URL with the fields in
  /// the query for a `GET`, the url-encoded body for anything else — so a
  /// stage that has to log in or search is one call rather than three details
  /// to get right. Inside a crawl this is what `next` returns:
  ///
  /// ```dart
  /// crawl([seed], next: (res) => switch (res.fetch.tag) {
  ///   null => [
  ///     res.parse(.html).form('#login')!
  ///         .at(res.url)
  ///         .fill({'user': user, 'pass': pass})
  ///         .fetch(tag: 'home'),
  ///   ],
  ///   _ => const <Fetch>[],
  /// });
  /// ```
  ///
  /// It was `Page.submit` through 5.5.0, a third public extension whose job
  /// was to queue this on an engine. De-duplication accounts for the body, so
  /// two searches for different terms are two requests.
  ///
  /// Throws [UnsupportedError] for a form declaring `multipart/form-data` —
  /// see [Form.multipart].
  Fetch fetch({
    String? tag,
    Object? meta,
    Map<String, String>? headers,
    int priority = 0,
    bool dedupe = true,
    int depth = 0,
  }) {
    if (multipart) {
      throw UnsupportedError(
        'This form is multipart/form-data, which Form does not encode. Build '
        'the request yourself with send(.post, url, body: ...).',
      );
    }
    return Fetch(
      url,
      method: method,
      body: method == HttpMethod.get ? null : Body.form(Map.of(fields)),
      headers: {..._referer(), ...?headers},
      tag: tag,
      meta: meta,
      priority: priority,
      dedupe: dedupe,
      depth: depth,
    );
  }

  /// Submits the form and returns the reply.
  ///
  /// Goes through [using], or the shared [get] — pass the client that
  /// fetched the page when it holds a session, so the cookies that came with
  /// the form go back with it:
  ///
  /// ```dart
  /// final session = Fetcher(session: true);
  /// final login = await session.send(.get, 'https://example.test/login'.url);
  /// final home = await login.parse(.html).form('#login')!
  ///     .at(login.url)
  ///     .fill({'user': 'me', 'pass': 'secret'})
  ///     .send(using: session);
  /// ```
  ///
  /// Inside a crawl use [fetch], which hands the request back for the
  /// frontier to schedule rather than sending it here and now.
  Future<Response> send({Send? using, Map<String, String>? headers}) {
    final send = using ?? Http.client.call;
    return send(fetch(headers: headers));
  }

  /// A `Referer` naming the page, when that page is one a server would
  /// accept.
  Map<String, String> _referer() {
    final from = page;
    return from.scheme == 'http' || from.scheme == 'https'
        ? {'Referer': from.toString()}
        : const {};
  }
}

/// Direct HTML form extraction from a [Response].
extension ResponseFormExtensions on Response {
  /// Finds the first `<form>` matching [selector] in this response's HTML,
  /// already resolved against this response's [url].
  ///
  /// ```dart
  /// // setup: final login = Response.text(''); final session = Fetcher();
  /// final home = await login.form('#login')!
  ///     .fill({'user': 'me', 'pass': 'secret'})
  ///     .send(using: session.call);
  /// ```
  Form? form([String selector = 'form']) {
    return parse<Markup>(DocumentFormat.html).form(selector)?.at(url);
  }
}
