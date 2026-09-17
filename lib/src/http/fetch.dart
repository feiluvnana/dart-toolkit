/// Shared by the format bridges in `html`, `xml` and `http`. Not exported.
library;

import 'dart:io';

import 'package:http/http.dart' as http;

import 'response.dart';

/// GETs [uri] and throws [HttpException] unless the status is 2xx.
Future<http.Response> fetchOk(Uri uri, Map<String, String>? headers, http.Client? client) async {
  final res = await uri.get(headers: headers, client: client);
  if (!res.ok) throw HttpException('GET failed with status ${res.statusCode}', uri: uri);
  return res;
}
