/// # HTML Forms (`Form`)
///
/// The other half of reading a page: a `<form>` a script can fill in and
/// send. [QueryResult.value] already reads a control the way a browser would
/// submit it; this collects every control on a form, lets a script override
/// the few it cares about, and works out where the result goes.
library;

import 'package:html/dom.dart';

import 'net.dart';

// ============================================================================
// HTML FORMS (Form)
// ============================================================================

/// A form on a page, ready to be filled in and sent.
///
/// Reached with [FormOnPage.form]. Its [fields] start as the page's own —
/// hidden inputs, a CSRF token, the options already selected — so a script
/// overrides the two it knows about and leaves the rest alone. That is the
/// difference between a login that works and one that does not:
///
/// ```dart
/// final page = await net.http.get('https://example.com/login'.url);
/// final res = await page.form('#login')!
///     .fill({'user': 'me', 'pass': secret})
///     .send();
/// ```
///
/// Inside a crawl, [FormSubmission.submit] schedules it through the engine
/// instead, so the response reaches a handler like any other page:
///
/// ```dart
/// await net.crawl<String>(seed)
///     .tag('results', (res) { ... })
///     .run((res) => res.submit(
///           res.form('form.search')!..fill({'q': 'widgets'}),
///           tag: 'results',
///         ));
/// ```
///
/// The body is `application/x-www-form-urlencoded`, which is what a form
/// sends unless it declares otherwise; a form with `enctype` set to
/// `multipart/form-data` — one that uploads a file — throws from [body]
/// rather than sending something the server cannot read.
final class Form {
  /// The `<form>` element this reads.
  final Element element;

  /// The page the form was found on, which relative actions resolve against.
  final Uri page;

  final Map<String, String> _fields;

  /// Reads the controls of [element], a `<form>` on [page].
  ///
  /// Prefer [FormOnPage.form], which finds the element and passes the page's
  /// URL for you. Construct one directly only for a form parsed out of markup
  /// that did not arrive as a response — and pass [page], or a relative
  /// `action` has nothing to resolve against.
  Form(this.element, {Uri? page})
    : page = page ?? Uri.parse('http://localhost'),
      _fields = _controls(element);

  /// The values this form would submit, in document order.
  ///
  /// The *successful controls*, as HTML calls them: every named control that
  /// is not disabled, with the value [QueryResult.value] reads — a select's
  /// chosen option, a textarea's text, a checkbox or radio only when it is
  /// ticked. A file input is skipped, having nothing on the page to read, and
  /// so are reset and plain buttons. The first submit button that carries a
  /// name is included, which is the one pressing Enter would activate.
  ///
  /// Two controls sharing one name — a checkbox group — keep the last, as
  /// [Body.form] does. Modify these through [fill].
  Map<String, String> get fields => Map.unmodifiable(_fields);

  /// Sets each entry of [values], adding names the form does not carry.
  ///
  /// Returns this form, so filling and sending read as one expression.
  Form fill(Map<String, String> values) {
    _fields.addAll(values);
    return this;
  }

  /// Where the form submits: its `action`, resolved against [page].
  ///
  /// An empty or missing `action` submits back to the page itself, as a
  /// browser does.
  Uri get action {
    final raw = element.attributes['action']?.trim();
    if (raw == null || raw.isEmpty) return page;
    return coerce(raw, base: page);
  }

  /// The method the form declares: [HttpMethod.post] for `method="post"`,
  /// and [HttpMethod.get] for anything else, which is what HTML allows.
  HttpMethod get method =>
      element.attributes['method']?.trim().toLowerCase() == 'post'
          ? HttpMethod.post
          : HttpMethod.get;

  /// The URL this submits to, [fields] included when the method is `GET`.
  ///
  /// A `GET` carries the form data in the query, *replacing* whatever query
  /// the action already had — again, what a browser does. Any other method
  /// leaves the action alone and carries the fields in [body].
  Uri get url {
    if (method == HttpMethod.get && _fields.isNotEmpty) {
      return action.replace(queryParameters: _fields);
    }
    return action;
  }

  /// The body this submits, or `null` for a `GET`, whose fields are in [url].
  ///
  /// Throws [UnsupportedError] for a form declaring `multipart/form-data`.
  /// Sending its fields url-encoded instead would be a request the server
  /// cannot parse, dressed as one it can, and the file such a form exists to
  /// carry is not on the page to be read.
  Body? get body {
    if (method == HttpMethod.get) return null;
    final enctype = element.attributes['enctype']?.trim().toLowerCase();
    if (enctype != null && enctype.startsWith('multipart/')) {
      throw UnsupportedError(
        'This form is $enctype, which Form does not encode. Build the '
        'request yourself with net.http.post(url, body: ...).',
      );
    }
    return Body.form(Map.of(_fields));
  }

  /// Submits the form and returns the response.
  ///
  /// Goes through [client], or the shared `net.http` — pass the client that
  /// fetched the page when it holds a session, so the cookies that came with
  /// the form go back with it:
  ///
  /// ```dart
  /// final session = Fetcher(session: true);
  /// final page = await session.get(url);
  /// final home = await page.form('#login')!
  ///     .fill({'user': user, 'pass': pass})
  ///     .send(client: session);
  /// ```
  ///
  /// Inside a crawl use [FormSubmission.submit], which schedules the request
  /// on the engine rather than fetching it here and now.
  Future<Reply> send({
    Fetcher? client,
    Map<String, String>? headers,
    Duration? timeout,
  }) => (client ?? net.http).send(
    method,
    url,
    body: body,
    headers: {..._referer(), ...?headers},
    timeout: timeout,
  );

  /// A `Referer` naming the page, when that page is one a server would accept.
  Map<String, String> _referer() =>
      page.scheme == 'http' || page.scheme == 'https'
          ? {'Referer': page.toString()}
          : const {};

  /// The successful controls of [form], keyed by name, in document order.
  static Map<String, String> _controls(Element form) {
    final fields = <String, String>{};
    Element? submit;

    const controls = 'input, select, textarea, button';
    for (final control in form.querySelectorAll(controls)) {
      final name = control.attributes['name']?.trim();
      if (name == null || name.isEmpty) continue;
      if (control.attributes.containsKey('disabled')) continue;

      final tag = control.localName?.toLowerCase();
      if (tag != 'input' && tag != 'button') {
        // A select or a textarea: whatever the one value reader says.
        fields[name] = control.value ?? '';
        continue;
      }

      // A <button> with no type is a submit button, as HTML says.
      final type =
          control.attributes['type']?.toLowerCase() ??
          (tag == 'button' ? 'submit' : 'text');
      switch (type) {
        case 'file':
        // Nothing on the page says which file, and a reset or a plain button
        // submits nothing at all.
        case 'reset':
        case 'button':
        case 'image':
          continue;
        case 'submit':
          // Only one submit button is sent: the one that was pressed. Pressing
          // Enter in a field activates the first, so that is the one taken.
          submit ??= control;
        case 'checkbox':
        case 'radio':
          // Reads null unless ticked, and an unticked box is not successful.
          if (control.value case final value?) fields[name] = value;
        default:
          // A text field with no value attribute still submits, empty.
          fields[name] = control.attributes['value'] ?? '';
      }
    }

    if (submit != null) {
      fields[submit.attributes['name']!.trim()] =
          submit.attributes['value'] ?? '';
    }
    return fields;
  }

  @override
  String toString() => 'Form(${method.wire} $action, ${_fields.length} fields)';
}

/// Finding a form on a page.
extension FormOnPage on Reply {
  /// The first form [selector] matches, or `null` when the page has none.
  ///
  /// [selector] is a full jQuery selector, so a form is namable by whatever
  /// distinguishes it — `'#login'`, `'form[action$=search]'`,
  /// `'form:has(input[type=password])'`. When it names something that is not
  /// a form, the first form inside it is used, so an id on a wrapper works
  /// as well as one on the form.
  ///
  /// ```dart
  /// final search = res.form('form.search');
  /// if (search != null) await search.fill({'q': 'widgets'}).send();
  /// ```
  Form? form([String selector = 'form']) {
    for (final element in $(selector)) {
      if (element.localName?.toLowerCase() == 'form') {
        return Form(element, page: url);
      }
      final inner = element.querySelector('form');
      if (inner != null) return Form(inner, page: url);
    }
    return null;
  }
}

/// Submitting a form from inside a crawl.
extension FormSubmission<T> on Page<T> {
  /// Schedules [form]'s submission on the engine, like [Page.follow].
  ///
  /// The method, the URL and the body all come from the form, so a stage that
  /// has to log in or search is one call rather than three details to get
  /// right. Everything [follow] does still applies: the `Referer` is set,
  /// [depth] grows by one, and de-duplication accounts for the body, so two
  /// searches for different terms are two requests.
  ///
  /// ```dart
  /// res.submit(res.form('#login')!.fill({'user': u, 'pass': p}), tag: 'home');
  /// ```
  ///
  /// Throws [StateError] when the response has no engine.
  void submit(
    Form form, {
    String? tag,
    Iterable<MapEntry<String, Object?>>? meta,
    Map<String, String>? headers,
    int priority = 0,
    bool dedupe = true,
  }) => follow(
    form.url.toString(),
    method: form.method,
    body: form.body,
    tag: tag,
    meta: meta,
    headers: headers,
    priority: priority,
    dedupe: dedupe,
  );
}
