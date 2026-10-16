// The DevTools protocol layer against a loopback fake browser: no Chrome.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/chrome.dart' show Chrome;
import 'package:dart_toolkit/src/cdp.dart';
import 'package:test/test.dart';

import 'support/capture.dart';

/// A fake browser endpoint: [answer] maps each command to its reply
/// (null: no reply); [events] lets a test push events.
final class Fake {
  Fake._(this._server);

  static Future<Fake> start({Map<String, Object?>? Function(Map<String, Object?> cmd)? answer}) async {
    final f = Fake._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    f._server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      f._ws = ws;
      f._connected.complete();
      ws.listen((data) {
        final cmd = (jsonDecode(data as String) as Map).cast<String, Object?>();
        f.commands.add(cmd);
        final reply = (answer ?? (_) => const {})(cmd);
        if (reply != null) ws.add(jsonEncode({'id': cmd['id'], ...reply}));
      });
    });
    return f;
  }

  final HttpServer _server;
  WebSocket? _ws;
  final _connected = Completer<void>();
  final commands = <Map<String, Object?>>[];

  String get url => 'ws://127.0.0.1:${_server.port}/devtools/browser/x';

  Future<void> event(String method, Map<String, Object?> params, {String? session}) async {
    await _connected.future;
    _ws!.add(jsonEncode({'method': method, 'params': params, 'sessionId': ?session}));
  }

  Future<void> close() async {
    await _ws?.close();
    await _server.close(force: true);
  }
}

void main() {
  late Fake fake;
  late Cdp cdp;
  setUp(() async {
    fake = await Fake.start(
      answer: (cmd) => switch (cmd['method']) {
        'Target.attachToTarget' => {
          'result': {'sessionId': 'S1'},
        },
        'Bad.call' => {
          'error': {'message': 'no such method'},
        },
        'Never.answer' => null,
        _ => {'result': <String, Object?>{}},
      },
    );
    cdp = await Cdp.connect(fake.url);
  });
  tearDown(() async {
    await cdp.close();
    await fake.close();
  });

  test('send returns the result; a protocol error is a BrowserException', () async {
    expect(await cdp.browser.send('Any.call'), isEmpty);
    await expectLater(
      cdp.browser.send('Bad.call'),
      throwsA(isA<BrowserException>().having((e) => e.message, 'message', 'Bad.call: no such method')),
    );
  });

  test('a flat session sends with its id and hears its own events', () async {
    final s = await cdp.attach('T1');
    await s.send('Page.enable');
    expect(fake.commands.last['sessionId'], 'S1');
    final heard = s.once('Page.loadEventFired');
    await fake.event('Page.loadEventFired', {'t': 1}, session: 'S1');
    expect(await heard, {'t': 1});
  });

  test('once filters with where and times out', () async {
    final next = cdp.browser.once('X.e', where: (e) => e['n'] == 2);
    await fake.event('X.e', {'n': 1});
    await fake.event('X.e', {'n': 2});
    expect((await next)['n'], 2);
    await expectLater(
      cdp.browser.once('X.never', timeout: const Duration(milliseconds: 50)),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('a pending call fails when the connection drops', () async {
    final pending = expectLater(cdp.browser.send('Never.answer'), throwsA(isA<BrowserException>()));
    await fake.close();
    await pending;
  });

  test('B5: send during and after close fails its future, nothing escapes', () async {
    final r = await capture(() async {
      final closing = cdp.close();
      final during = expectLater(cdp.browser.send('Any.call'), throwsA(isA<BrowserException>()));
      await closing;
      await during;
      await expectLater(cdp.browser.send('Any.call'), throwsA(isA<BrowserException>()));
    });
    expect(r.err, isEmpty);
  });

  test('B7: a where that throws fails its once instead of timing out', () async {
    final next = cdp.browser.once(
      'X.e',
      where: (e) => (e['n']! as String).isEmpty, // a bad cast on an int
      timeout: const Duration(seconds: 5),
    );
    await fake.event('X.e', {'n': 1});
    await expectLater(next, throwsA(isA<TypeError>()));
  });

  test('B12: connect and launch failures are BrowserExceptions that say why', () async {
    await expectLater(
      Chrome.connect('http://127.0.0.1:1'),
      throwsA(isA<BrowserException>().having((e) => e.message, 'message', contains('no browser to connect to'))),
    );
    final junk = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => junk.close(force: true));
    junk.listen((r) => r.response
      ..write('not json')
      ..close());
    await expectLater(Chrome.connect('http://127.0.0.1:${junk.port}'), throwsA(isA<BrowserException>()));
    if (Platform.isWindows) return;
    final dir = await Directory.systemTemp.createTemp('fake_chrome');
    addTearDown(() => dir.delete(recursive: true));
    final fake = File('${dir.path}/chrome')..writeAsStringSync('#!/bin/sh\necho "bad flag --x" >&2\nexit 3\n');
    await Process.run('chmod', ['+x', fake.path]);
    await expectLater(
      Chrome.launch(path: fake.path),
      throwsA(isA<BrowserException>().having((e) => e.message, 'message', contains('bad flag --x'))),
    );
  });

  test('S12: a proxy password never reaches Chrome\'s argv', () async {
    await expectLater(
      Chrome.launch(proxy: 'http://user:SECRET@127.0.0.1:8080'),
      throwsA(isA<ArgumentError>().having((e) => '$e', 'text', allOf(contains('no proxy password'), isNot(contains('SECRET'))))),
    );
  });
}
