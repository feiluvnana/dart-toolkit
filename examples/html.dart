/// html: CSS selectors over a forgiving parser; links resolve against a base.
///
/// `dart run examples/html.dart`
library;

import 'package:dart_toolkit/html.dart';

void main() {
  final doc = Html.parse('''
<html><body><h1>Albums</h1>
<ul><li><a class=item href="/a/1">First</a></li><li><a class=item href="/a/2">Second</a></li></ul>
<script>ignored()</script></body></html>''', base: 'https://example.com/list');
  print(doc.$('h1').text()); // Albums
  print(doc.$('a.item').attrs('href')); // absolute URLs
  print(doc.$('a.item').texts()); // [First, Second]
  print(doc.not('script').$('body').text());
}
