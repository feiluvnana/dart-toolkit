/// # HTTP & Web Scraping
///
/// Requests on `Uri` over [IoClient], a Scrapy-style crawler, atomic downloads, and the
/// [Http.scope] client seam. Parsing is `formats.dart`; the Chrome client is `chrome.dart`.
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

part 'src/http/cache.dart';
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
