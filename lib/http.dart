/// # HTTP & Web Scraping
///
/// Requests and JSON on `Uri` and `http.Response`, a Scrapy-style scraping
/// pipeline, atomic downloads and the shared-client session seam. HTML and XML
/// parsing are in `html/html.dart` and `xml/xml.dart`.
///
/// {@category Crawling}
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'async.dart';
import 'core.dart';
import 'fs.dart';
import 'util.dart';

part 'src/http/download.dart';
part 'src/http/response.dart';
part 'src/http/scrape.dart';
part 'src/http/session.dart';
