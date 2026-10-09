/// # Crawling
///
/// `url.crawl<T>(…)` and the [Crawler] class: pages fetched at most 8 at a time (4 per host),
/// read by hooks that emit items and follow links, as a `Batch` of pages ([Crawl]) whose items
/// stream as they are found. robots.txt, sitemaps, a depth and page budget, and a store to
/// resume from. Every request goes out as `Http.scope` says.
///
/// {@category Crawling}
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'html.dart';
import 'json.dart';
import 'src/core.dart';
import 'src/http.dart';
import 'src/html.dart' show HtmlInternals;
import 'src/message.dart';
import 'xml.dart';

export 'html.dart';
export 'http.dart';
export 'json.dart';
export 'xml.dart';

part 'src/http/crawl_store.dart';
part 'src/http/robots.dart';
part 'src/http/scrape.dart';
