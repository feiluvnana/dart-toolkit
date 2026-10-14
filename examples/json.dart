/// json: dotted paths, typed reads with fallbacks, `*` over arrays.
///
/// `dart run examples/json.dart`
library;

import 'package:dart_toolkit/json.dart';

void main() {
  final doc = Json.parse('{"server":{"port":8080},"users":[{"name":"Ada","tags":[1,2]},{"name":"Lin"}]}');
  print(doc.$('server.port').or(80)); // 8080
  print(doc.$('server.host').or('localhost')); // missing -> fallback
  print(doc.$('users.*.name').asList<String>()); // [Ada, Lin]
  print(doc.$('users.1.tags').asList<int>()); // [] when missing
  print(Json.encode({'ok': true, 'n': doc.$('users').length}, pretty: true));
}
