/// # Chrome
///
/// [ChromeClient], a [Client] that renders pages in the installed Chrome over the DevTools
/// protocol, and [ChromePage], a tab to click, fill and wait on. No third-party package, no
/// Chromium download.
///
/// Not in the barrel, so scripts that never open a browser do not compile it:
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
