/// # HTTP & Web Scraping
///
/// Requests and JSON on `Uri` and `http.Response`, a Scrapy-style scraping
/// pipeline, atomic downloads and the shared-client session seam. HTML and XML
/// parsing are in `html/html.dart` and `xml/xml.dart`.
///
/// {@category Crawling}
library;

export '../src/http/download.dart';
export '../src/http/response.dart';
export '../src/http/session.dart' show Http;
export '../src/http/scrape.dart';
