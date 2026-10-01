/// # Chrome
///
/// [ChromeClient], a [Client] that renders every page in the Chrome already installed and
/// answers with the DOM its scripts built, and [ChromePage], a tab to click, fill and wait on.
/// It speaks the DevTools protocol over a websocket: no third-party package, no Chromium
/// download.
///
/// Not in the `dart_toolkit.dart` barrel: it is a third of `http`'s source, and a script that
/// never opens a browser should not compile it. Import it beside `http.dart` (or the barrel):
///
/// ```dart
/// import 'package:dart_toolkit/chrome.dart';
/// import 'package:dart_toolkit/dart_toolkit.dart';
/// ```
///
/// {@category Networking}
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'async.dart';
import 'fs.dart';
import 'formats.dart';
import 'http.dart';

part 'src/chrome/browser.dart';
part 'src/chrome/client.dart';
part 'src/chrome/page.dart';
