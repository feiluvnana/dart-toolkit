// Launches Chromium, says "up", then waits for a line on stdin without
// closing it: the test ends Chromium meanwhile, and its watchdog must go
// with it while this script still runs.
import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/chrome.dart';

Future<void> main() async {
  final browser = await Chrome.launch();
  await browser.open('data:text/html,<p>hi</p>');
  print('up');
  await stdin.transform(utf8.decoder).first;
}
