/// # HTTP & Web Scraping
///
/// `Request`, `Response` and `Client` — over `dart:io` as [IoClient], over Chrome's DevTools
/// protocol as [ChromeClient] — requests and JSON on `Uri`, a Scrapy-style scraping pipeline,
/// atomic downloads and the shared-client scope seam. Parsing is in `formats.dart`.
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
import 'hash.dart';
import 'native.dart';

part 'src/http/chrome.dart';
part 'src/http/client.dart';
part 'src/http/cookies.dart';
part 'src/http/documents.dart';
part 'src/http/encoding.dart';
part 'src/http/download.dart';
part 'src/http/uri.dart';
part 'src/http/verbs.dart';
part 'src/http/robots.dart';
part 'src/http/scrape.dart';
part 'src/http/scope.dart';
