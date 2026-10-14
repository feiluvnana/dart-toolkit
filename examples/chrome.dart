/// chrome: drive a real browser. The first run downloads Chromium once; needs network.
///
/// `dart run examples/chrome.dart`
library;

import 'dart:io' show Directory;

import 'package:dart_toolkit/chrome.dart';
import 'package:dart_toolkit/fs.dart';

Future<void> main() async {
  final browser = await Chrome.launch();
  try {
    final page = await browser.open('https://example.com');
    print(await page.html().$('h1').text()); // Example Domain
    print(await page.run<int>('document.links.length'));
    final shot = Fs.dir(Directory.systemTemp.path).file('example.png');
    await (page.screenshot() > shot);
    print('screenshot: ${await shot.size()} bytes');
  } finally {
    await browser.close();
  }
}
