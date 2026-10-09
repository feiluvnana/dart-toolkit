/// # HTTP
///
/// Requests on `Uri` as `Task`s ([UriVerbs]), downloads ([UriDownload]), server-sent events,
/// and [Http.scope], where the client, timeout, credentials, cookies, cache, retries and per-host
/// limits are set for a block. Parsing a body is the format libraries' (`html.dart`,
/// `json.dart`, `xml.dart`); crawling is `scrape.dart`; the browser is `chrome.dart`.
///
/// {@category Networking}
library;

export 'core.dart';
export 'hash.dart' show Hash, Hex, StringHexExtensions;

export 'src/http.dart' hide HttpBridge, HttpInternals;
export 'src/message.dart' hide MessageInternals;
export 'dart:io' show HttpException;
