/// Ultra-minimal browser automation. Thin facade over `package:puppeteer`:
/// same tiny syntax, the engine underneath.
///
/// ```dart
/// final browser = await Chrome.launch();
/// final page = await browser.open('https://example.com');
/// await page.wait(Duration(seconds: 2));
/// final doc = await page.html();      // Elements — the html module's type
/// doc.$('a.item')[0].text();
/// await page.text();
/// await page.click('#next');
/// await page.type('#q', 'hello');
/// await page.screenshot('out.png');
/// await browser.close();
/// ```
///
/// Public surface is exactly: [Chrome], [Browser], [Page].
/// Everything else is private.
library;

import 'dart:io';

import 'package:dart_toolkit/html.dart';
import 'package:puppeteer/puppeteer.dart' as pp;

/// Entry point: launch Chromium. Throws if the browser cannot start.
abstract final class Chrome {
  /// Launch headless Chromium. Downloads it on first run unless [path]
  /// points at a system Chrome/Chromium executable.
  static Future<Browser> launch({
    bool headless = true,
    String? path,
  }) async {
    final browser = await pp.puppeteer.launch(
      headless: headless,
      executablePath: path,
    );
    return Browser._(browser);
  }
}

/// An open browser. Owns its pages; one browser serves many pages.
final class Browser {
  Browser._(this._browser);

  final pp.Browser _browser;

  /// New tab + goto [url] (waits for load).
  Future<Page> open(String url) async {
    final page = await _browser.newPage();
    await page.goto(url);
    return Page._(page);
  }

  /// Close the browser and all its pages.
  Future<void> close() => _browser.close();
}

/// An open tab. Read with [html]/[text], drive with [click]/[type]/[eval].
final class Page {
  Page._(this._page);

  final pp.Page _page;
  var _dismissing = false;

  /// Parsed rendered DOM — the html module's [Elements].
  Future<Elements> html() async => Html.parse(await _page.content ?? '');

  /// Full page text (rendered).
  Future<String> text() async =>
      (await _page.evaluate<String?>(
        'document.documentElement.innerText',
      )) ??
      '';

  /// Plain sleep, e.g. to let JS settle. Never throws.
  Future<void> wait(Duration duration) => Future<void>.delayed(duration);

  /// Re-navigate this tab (waits for load).
  Future<void> goto(String url) async {
    await _page.goto(url);
  }

  /// Click first match of [selector]. Throws if none.
  Future<void> click(String selector) => _page.click(selector);

  /// Type [value] into first match of [selector]. Throws if none.
  Future<void> type(String selector, String value) =>
      _page.type(selector, value);

  /// Run [code] as JS, returning its string result (`null` for null).
  /// Code must evaluate to a string — stringify in JS for other types.
  Future<String?> eval(String code) => _page.evaluate<String?>(code);

  /// Auto-dismiss all JS dialogs (alert/confirm/prompt) from now on.
  Future<void> dismiss() async {
    if (_dismissing) return;
    _dismissing = true;
    _page.onDialog.listen((dialog) async {
      await dialog.dismiss();
    });
  }

  /// Viewport PNG screenshot saved to [path].
  Future<void> screenshot(String path) async {
    final bytes = await _page.screenshot();
    await File(path).writeAsBytes(bytes);
  }

  /// Close this tab.
  Future<void> close() => _page.close();
}
