/// What a browser-driven run needs from a browser, without importing `chrome`
/// (puppeteer is most of such a script's startup). `chrome`'s Browser and
/// Page implement these.
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
