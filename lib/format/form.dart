/// # HTML Forms (`Form`)
///
/// The other half of reading a page: a `<form>` a script can fill in and
/// send. [Markup.value] already reads a control the way a browser would
/// submit it; this collects every control on a form, lets a script override
/// the few it cares about, and works out where the result goes.
///
/// **Reading a `<form>` is HTML; sending one is `net`.** This half declared
/// itself inside `net` through 5.5.0 — an extension on a `format.html` type,
/// walking a parsed DOM, in the domain whose own doc says it parses nothing.
/// The sending half is the `Sending` extension over in `net`, which is the
/// same shape as `io` declaring `Sequence.dump` on a `collection` type.
library;

import 'package:html/dom.dart';

import '../src/markup.dart';
import '../src/method.dart';

// ============================================================================
// HTML FORMS (Form)
// ============================================================================

/// A form on a page, ready to be filled in and sent.
///
/// Reached with [FormOnMarkup.form]. Its [fields] start as the page's own —
/// hidden inputs, a CSRF token, the options already selected — so a script
/// overrides the two it knows about and leaves the rest alone. That is the
/// difference between a login that works and one that does not:
///
/// ```dart
/// final login = await Http.get('https://example.com/login'.url);
/// final sent = await login.parse(Codec.html).form('#login')!
///     .at(login.url)
///     .fill({'user': 'me', 'pass': secret})
///     .send();
/// ```
///
/// Inside a crawl, `form.at(res.url).fetch` is the request to return from
/// `next`, so the reply reaches the crawl like any other page:
///
/// ```dart no-compile
/// net.crawl([Fetch(seed)].seq, (res) => switch (res.fetch.tag) {
///   null => [
///     res.parse(format.html).form('form.search')!
///         .at(res.url)
///         .fill({'q': 'widgets'})
///         .fetch(tag: 'results'),
///   ].seq,
///   _ => const Sequence.empty(),
/// });
/// ```
///
/// The body is `application/x-www-form-urlencoded`, which is what a form
/// sends unless it declares otherwise; a form with `enctype` set to
/// `multipart/form-data` — one that uploads a file — throws from [body]
/// rather than sending something the server cannot read.
final class Form {
  /// The `<form>` element this reads.
  final Element element;

  Uri? _page;

  final Map<String, String> _fields;

  /// Reads the controls of [element], a `<form>` on [page].
  ///
  /// Prefer [FormOnMarkup.form], which finds the element for you. Construct
  /// one directly only for a form parsed out of markup that did not arrive as
  /// a response — and pass [page], or a relative `action` has nothing to
  /// resolve against.
  Form(this.element, {Uri? page}) : _page = page, _fields = _controls(element);

  /// The page this form was found on, which relative actions resolve against.
  ///
  /// Set by [at], or by the constructor. A form read out of loose markup has
  /// no page, and asking for one throws rather than quietly resolving against
  /// `localhost` — a request to the wrong host is worse than an error.
  Uri get page =>
      _page ??
      (throw StateError(
        'This form has no page to resolve its action against. It was read '
        'from markup rather than from a response, so tell it where that '
        'markup came from: form.at(res.url).',
      ));

  /// This form, resolving relative actions against [page].
  ///
  /// Reading a page is `format.html` and no longer knows what URL it came
  /// from, so the response hands that over here:
  ///
  /// ```dart
  /// final res = await Http.get(url);
  /// await res.parse(Codec.html).form('#login')!
  ///     .at(res.url)
  ///     .fill({'user': user, 'pass': pass})
  ///     .send();
  /// ```
  ///
  /// Chainable, like [fill].
  Form at(Uri page) {
    _page = page;
    return this;
  }

  /// The values this form would submit, in document order.
  ///
  /// The *successful controls*, as HTML calls them: every named control that
  /// is not disabled, with the value [Markup.value] reads — a select's
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
    return page.resolve(raw);
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

  /// Whether this form declares an encoding this library cannot build.
  ///
  /// True for `multipart/form-data` — the one that uploads a file, which is
  /// not on the page to be read. `Sending.fetch` throws for it rather than
  /// sending url-encoded fields the server cannot parse, dressed as ones it
  /// can.
  bool get multipart {
    final enctype = element.attributes['enctype']?.trim().toLowerCase();
    return enctype != null && enctype.startsWith('multipart/');
  }

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

/// Finding a form on a parsed page.
extension FormOnMarkup on Markup {
  /// The first form [selector] matches, or `null` when the page has none.
  ///
  /// [selector] is a full jQuery selector, so a form is namable by whatever
  /// distinguishes it — `'#login'`, `'form[action$=search]'`,
  /// `'form:has(input[type=password])'`. When it names something that is not
  /// a form, the first form inside it is used, so an id on a wrapper works
  /// as well as one on the form.
  ///
  /// A cursor has no idea what URL its markup came from, so a form that
  /// submits to a relative `action` needs [Form.at] before it is sent:
  ///
  /// ```dart
  /// final res = await Http.get(url);
  /// final search = res.parse(Codec.html).form('form.search');
  /// if (search != null) await search.at(res.url).fill({'q': 'widgets'}).send();
  /// ```
  Form? form([String selector = 'form']) {
    for (final element in $(selector).elements) {
      if (element.localName?.toLowerCase() == 'form') return Form(element);
      final inner = element.querySelector('form');
      if (inner != null) return Form(inner);
    }
    return null;
  }
}
