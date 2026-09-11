/// # HTTP Methods (`HttpMethod`)
///
/// The verb a request carries. It lives in `lib/src/` for the reason [Codec]
/// does: a `<form method="post">` is something `format.html` reads and
/// something `net` sends, and neither domain may depend on the other, so the
/// value belongs to no domain. It is exported from the package root either
/// way.
library;

// ============================================================================
// HTTP METHODS (HttpMethod)
// ============================================================================

/// HTTP verbs supported by `Fetcher.send`.
enum HttpMethod {
  /// Retrieve a resource.
  get,

  /// Submit a body to a resource.
  post,

  /// Replace a resource.
  put,

  /// Remove a resource.
  delete,

  /// Partially update a resource.
  patch,

  /// Retrieve only the headers of a resource.
  head;

  /// The uppercase wire representation, e.g. `'GET'`.
  String get wire => name.toUpperCase();

  /// The method [wire] names, or [get] when it names none.
  static HttpMethod of(String wire) {
    final upper = wire.trim().toUpperCase();
    for (final method in values) {
      if (method.wire == upper) return method;
    }
    return HttpMethod.get;
  }
}
