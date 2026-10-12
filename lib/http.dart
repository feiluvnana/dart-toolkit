/// # HTTP
///
/// A small HTTP/1.1 client — `Http.get`, `post`, `put`, `delete` — returning a
/// lazy `Request`: `await` gives the streaming `Response`, a reading or `pipe`
/// reads the body. A non-2xx reading throws an `HttpException`;
/// `pipe(file, resume: true)` resumes with `Range`.
library;

export 'src/http/http.dart';
export 'src/core/errors.dart';
export 'src/core/pipe.dart';
export 'src/core/traits.dart';
