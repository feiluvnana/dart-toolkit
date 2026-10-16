// Launches Chromium, reads a page and returns without close(): the script
// must exit by itself and the watchdog must end Chromium.
import 'package:dart_toolkit/chrome.dart';

Future<void> main() async {
  final browser = await Chrome.launch();
  final page = await browser.open('data:text/html,<p>hi</p>');
  print((await page.html()).text());
}
