/// # HTTP
///
/// A small HTTP/1.1 client — `Http.get`, `post`, `put`, `delete`, `head` — returning a
/// streaming `Resp` (itself a `Reader`: `Http.get(url).pipe(File('huge.iso'))`) with strict
/// `text()`, `json()` and `bytes` (a non-2xx throws a `StatusException`), plus resumable
/// `download` with `retry` and `timeout` throughout.
library;

export 'src/http/http.dart';
