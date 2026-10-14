/// What a crawl needs from a browser, so `scrape` never imports `chrome`
/// (puppeteer is most of a scrape script's startup). `chrome`'s Browser and
/// Page implement these; a crawl takes any Browser as is.
library;

/// Opens tabs: `chrome`'s Browser.
abstract interface class TabHost {
  Future<TabView> open(String url, {Map<String, String>? headers, Duration? timeout});
}

/// One tab: `chrome`'s Page.
abstract interface class TabView {
  Future<TabView> go(String url, {Duration? timeout});
  Future<T?> run<T>(String js);
  Future<String> url();
  Future<void> close();
}
