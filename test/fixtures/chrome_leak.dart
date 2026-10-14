// Launches Chromium, then throws without close(): the watchdog must clean up.
import 'package:dart_toolkit/chrome.dart';

Future<void> main() async {
  await Chrome.launch();
  print('ready');
  throw StateError('boom');
}
