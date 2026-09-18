/// # HTTP & Web Scraping
///
/// `Request`, `Response` and `Client` over `dart:io`, requests and JSON on `Uri`, a
/// Scrapy-style scraping pipeline, atomic downloads and the shared-client session seam.
/// HTML and XML parsing are in `html.dart` and `xml.dart`; a mock client is in `testing.dart`.
///
/// {@category Crawling}
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'async.dart';
import 'core.dart';
import 'formats.dart';
import 'fs.dart';

part 'src/http/client.dart';
part 'src/http/documents.dart';
part 'src/http/download.dart';
part 'src/http/uri.dart';
part 'src/http/scrape.dart';
part 'src/http/session.dart';
