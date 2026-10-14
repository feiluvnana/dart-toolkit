/// image: decode any format, resize, re-encode; `sniff` names a format from its first bytes.
///
/// `dart run examples/image.dart`
library;

import 'dart:convert' show base64;

import 'package:dart_toolkit/image.dart';

Future<void> main() async {
  final png = base64.decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  );
  print(Image.sniff(png)); // png
  final big = Image.decode(png).resize(width: 64);
  print('${big.width()}x${big.height()}');
  final jpg = await big.encode(.jpg, quality: 80).bytes();
  print('${Image.sniff(jpg)} ${jpg.length} bytes');
}
