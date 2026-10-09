/// # Chrome
///
/// [Chrome], a [Client] that renders pages in the installed Chrome over the DevTools protocol,
/// and [Page], a tab to click, fill and wait on. [Browser] says how Chrome is started, [Render]
/// how a page is read. No third-party package, no Chromium download.
///
/// Its own import, so scripts that never open a browser do not compile it:
///
/// ```dart
/// import 'package:dart_toolkit/chrome.dart';
/// ```
///
/// {@category Networking}
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'html.dart';
import 'json.dart';
import 'src/core.dart';
import 'src/http.dart';
import 'src/message.dart';

export 'html.dart';
export 'http.dart';
export 'json.dart';

part 'src/chrome/browser.dart';
part 'src/chrome/client.dart';
part 'src/chrome/page.dart';
