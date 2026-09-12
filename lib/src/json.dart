/// # JSON Cursors (`Json`)
///
/// A read cursor over a decoded JSON document. The HTML side of this library
/// hands back a [Markup] and nobody casts; this is the same idea for the
/// other format a script meets constantly.
///
/// The type lives here, in `lib/src/`, because it belongs to no single
/// domain: `net` hands one back from a response, `format` from a document.
/// It sat under `lib/util/` through 5.4.0 and was never reachable as `util.`
/// anything — a directory named after an accessor should hold that
/// accessor's members. It is exported from the package root exactly as
/// before. The *codecs* are `format.json`, beside `format.yaml` and
/// `format.toml`, because a format is knowledge from outside Dart.
///
/// Three doors produce the same cursor:
///
/// ```dart
/// res.parse(format.json).at('data.items');   // a response
/// format.json.parse(text);                   // a string
/// await format.json.read('config.json');     // a file
/// ```
///
/// Navigation comes in two spellings, for the two questions: [Json.at] walks a
/// dotted path to one node, and [Json.jsonpath] runs a JSONPath query and
/// returns every match.
library;

import '../src/jsonpath.dart';
import '../src/jsontext.dart';

// ============================================================================
// JSON CURSORS (Json)
// ============================================================================

/// A cursor over a decoded JSON document.
///
/// Reads never throw and never cast: a path that is not there, or holds
/// something other than what was asked for, reads as `null` — the same
/// contract [Slot.read], `Field.text` and [Sequence.first] keep, because the
/// caller asked for a value and the honest answer is that there is not one.
///
/// ```dart
/// final doc = format.json.parse(body);
///
/// doc.text('data.user.name');                   // String?
/// doc.number('data.total');                     // num?
/// doc.flag('data.active');                      // bool?
/// doc.at('data.items').all((item) => (
///   id: item.number('id'),
///   name: item.text('name'),
/// ));                                           // Sequence<({num? id, String? name})>
/// ```
///
/// There are no [Slot]s here. A slot exists so a *writer* and a *reader* in
/// different places can agree on a key; reading a document is one place.
/// `Slot` is the two-places case, and keeps its own typed keys.
final class Json {
  /// The decoded value underneath — the escape hatch, and where a typed build
  /// of the whole document starts:
  ///
  /// ```dart
  /// final config = Config.fromJson((await format.json.read(path)).raw);
  /// ```
  final Object? raw;

  /// Wraps an already-decoded [raw] value.
  ///
  /// Reach for `format.json.parse`, `format.json.read` or `Reply.at` instead; this
  /// is for a document that arrived decoded from somewhere else.
  const Json(this.raw);

  /// The empty cursor — what a missing path reads as.
  static const Json none = Json(null);

  /// The value at a dotted [path], as a cursor of its own.
  ///
  /// Segments are separated by `.`, and an array index is either bracketed or
  /// just a number: `'data.items[0].name'` and `'data.items.0.name'` are the
  /// same path. A segment that is not there gives the empty cursor, so a long
  /// path never throws part way down.
  Json at(String path) {
    Object? node = raw;
    for (final step in _steps(path)) {
      if (step.isEmpty) continue;
      switch (node) {
        case Map<String, Object?> map:
          node = map[step];
        case Map<Object?, Object?> map:
          node = map[step];
        case List<Object?> list:
          final index = int.tryParse(step);
          node = index != null && index >= 0 && index < list.length
              ? list[index]
              : null;
        default:
          return none;
      }
      if (node == null) return none;
    }
    return Json(node);
  }

  static Iterable<String> _steps(String path) =>
      path.replaceAll('[', '.').replaceAll(']', '').split('.');

  /// Every value a JSONPath [expression] selects.
  ///
  /// Where [at] walks one dotted path to one node, this runs a query and hands
  /// back all of the matches — the JSON side of `Markup.\$xpath`, and named
  /// after its language for the same reason:
  ///
  /// ```dart
  /// final doc = format.json.parse(body);
  ///
  /// doc.jsonpath(r'$.store.book[*].author');        // every author
  /// doc.jsonpath(r'$..price').transform(.map.nonnull((p) => p.number()));
  /// doc.jsonpath(r'$.store.book[?(@.price < 10)]')  // the cheap ones
  ///    .transform(.map.nonnull((b) => b.text('title')));
  /// ```
  ///
  /// The supported syntax:
  ///
  /// | Form | Selects |
  /// | :--- | :--- |
  /// | `$` | the root; optional, so `store.book` works too |
  /// | `.name`, `['name']`, `["name"]` | one child |
  /// | `['a','b']` | several named children |
  /// | `.*`, `[*]` | every child of a map or list |
  /// | `..name`, `..*` | that name anywhere below, at any depth |
  /// | `[0]`, `[-1]`, `[0,2]` | list positions, negative from the end |
  /// | `[1:4]`, `[:3]`, `[::2]`, `[::-1]` | slices, with an optional step |
  /// | `[?(@.field)]` | children that have that field |
  /// | `[?(@.price < 10)]` | `==` `!=` `<` `<=` `>` `>=` against a literal |
  /// | `[?(@.name =~ /^wid/)]` | a regular-expression match |
  ///
  /// Deliberately absent: script expressions, `$` inside a filter, and
  /// arithmetic. Each is a language rather than a query, and a filter that
  /// needs one is a `keep` on the [Sequence] this returns.
  ///
  /// An expression this reader cannot parse selects nothing, matching how a
  /// missing path reads: a typo mid-crawl is an empty result to notice, not an
  /// exception to catch.
  List<Json> jsonpath(String expression) =>
      JsonPath.of(expression).read(raw).map(Json.new).toList();

  /// The text at [path], or of this node when [path] is omitted.
  ///
  /// A number or a boolean is rendered as text, because a document that quotes
  /// its numbers one release and stops the next should not break a reader. A
  /// map, a list and a missing path all read `null`.
  String? text([String? path]) {
    final node = path == null ? raw : at(path).raw;
    return switch (node) {
      String value => value,
      num value => '$value',
      bool value => '$value',
      _ => null,
    };
  }

  /// The number at [path], or of this node when [path] is omitted.
  ///
  /// A numeric string parses, so `"42"` and `42` both read.
  num? number([String? path]) {
    final node = path == null ? raw : at(path).raw;
    return switch (node) {
      num value => value,
      String value => num.tryParse(value.trim()),
      _ => null,
    };
  }

  /// The boolean at [path], or of this node when [path] is omitted.
  ///
  /// `"true"` and `"false"` parse; anything else reads `null`.
  bool? flag([String? path]) {
    final node = path == null ? raw : at(path).raw;
    return switch (node) {
      bool value => value,
      'true' => true,
      'false' => false,
      _ => null,
    };
  }

  /// One [R] per element of this node, each built from its own cursor.
  ///
  /// This is how a repeated sub-object comes back typed, and it is the JSON
  /// half of `Markup.all`:
  ///
  /// ```dart
  /// final items = res.parse(format.json).at('data.items').all((item) => (
  ///   sku: item.text('sku'),
  ///   price: item.number('price.amount'),
  /// ));
  /// ```
  ///
  /// A node that is not an array counts as one element, and the empty cursor
  /// as none.
  List<R> all<R>(R Function(Json item) build) =>
      _elements().map(build).toList();

  /// How many elements or keys this node holds.
  ///
  /// A scalar counts as one and the empty cursor as none, so [count] answers
  /// "how much is here" for every shape a document can take.
  int get count => switch (raw) {
    null => 0,
    List<Object?> list => list.length,
    Map<Object?, Object?> map => map.length,
    _ => 1,
  };

  /// Whether this node holds nothing — which a missing path always does.
  ///
  /// No complement: `!doc.empty` already says the other thing.
  bool get empty => count == 0;

  /// Converts this JSON cursor to a native [Map] if it represents a JSON object, or `null` otherwise.
  Map<String, T>? toMap<T>() => switch (raw) {
    Map<String, T> map => map,
    Map<Object?, Object?> map => {
      for (final entry in map.entries) entry.key.toString(): entry.value as T,
    },
    _ => null,
  };

  /// Converts this JSON cursor to a native [List] if it represents a JSON array, or `null` otherwise.
  List<T>? toList<T>() => switch (raw) {
    List<T> list => list,
    List<Object?> list => list.cast<T>(),
    _ => null,
  };

  Iterable<Json> _elements() => switch (raw) {
    null => const <Json>[],
    List<Object?> list => list.map(Json.new),
    _ => [this],
  };

  @override
  String toString() => 'Json(${JsonText.describe(raw)})';
}
