/// The forms a page carries: what a `Form` collects, where it decides to
/// send it, and the two ways of sending it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

const _login = '''
<html><body>
  <div id="panel">
    <form id="login" action="/session" method="POST">
      <input type="hidden" name="csrf" value="tok-123">
      <input type="text" name="user">
      <input type="password" name="pass" value="">
      <input type="checkbox" name="remember" value="yes" checked>
      <input type="checkbox" name="spam" value="1">
      <input type="radio" name="plan" value="free">
      <input type="radio" name="plan" value="pro" checked>
      <select name="lang">
        <option value="en">English</option>
        <option value="fr" selected>French</option>
      </select>
      <textarea name="note">a note</textarea>
      <input type="file" name="avatar">
      <input type="text" name="ignored" value="x" disabled>
      <input type="reset" name="clear" value="Clear">
      <input value="unnamed">
      <button type="submit" name="do" value="login">Log in</button>
      <button type="submit" name="cancel" value="1">Cancel</button>
    </form>
  </div>
  <form class="search" action="/search?stale=1"><input name="q" value="dart"></form>
  <form class="upload" method="post" enctype="multipart/form-data">
    <input type="text" name="title" value="t">
  </form>
</body></html>
''';

Reply _page([String markup = _login]) =>
    Reply.text(markup, requested: 'https://example.com/login'.url);

void main() {
  group('Form.fields', () {
    test('collects the successful controls the way a browser would', () {
      expect(_page().form('#login')!.fields, {
        'csrf': 'tok-123',
        // A text field with no value attribute still submits, empty.
        'user': '',
        'pass': '',
        // Only the ticked box and the chosen radio.
        'remember': 'yes',
        'plan': 'pro',
        'lang': 'fr',
        'note': 'a note',
        // The first submit button, the one Enter would press.
        'do': 'login',
      });
    });

    test('skips what a browser would not send', () {
      final fields = _page().form('#login')!.fields;
      expect(fields.containsKey('spam'), isFalse, reason: 'unticked');
      expect(fields.containsKey('avatar'), isFalse, reason: 'a file input');
      expect(fields.containsKey('ignored'), isFalse, reason: 'disabled');
      expect(fields.containsKey('clear'), isFalse, reason: 'a reset button');
      expect(
        fields.containsKey('cancel'),
        isFalse,
        reason: 'the second submit',
      );
      expect(fields.values, isNot(contains('unnamed')));
    });

    test('fill overrides what the page carried and adds what it did not', () {
      final form = _page().form('#login')!.fill({
        'user': 'me',
        'pass': 'secret',
        'extra': '1',
      });

      expect(form.fields['user'], 'me');
      expect(form.fields['pass'], 'secret');
      expect(form.fields['extra'], '1');
      // Everything else is still the page's own.
      expect(form.fields['csrf'], 'tok-123');
    });

    test('the fields it hands out cannot be edited behind its back', () {
      expect(
        () => _page().form('#login')!.fields['user'] = 'me',
        throwsUnsupportedError,
      );
    });
  });

  group('Form addressing', () {
    test('resolves the action against the page and reads the method', () {
      final form = _page().form('#login')!;
      expect(form.method, HttpMethod.post);
      expect(form.action, Uri.parse('https://example.com/session'));
      expect(form.url, Uri.parse('https://example.com/session'));
      expect(form.body, isA<FormBody>());
      expect(utf8.decode(form.body!.bytes()), contains('csrf=tok-123'));
    });

    test('a GET form carries its fields in the query, replacing it', () {
      final form = _page().form('form.search')!;
      expect(form.method, HttpMethod.get);
      expect(form.body, isNull);
      // The action's own `stale=1` goes, as it does in a browser.
      expect(form.url, Uri.parse('https://example.com/search?q=dart'));

      form.fill({'q': 'widgets', 'page': '2'});
      expect(form.url.queryParameters, {'q': 'widgets', 'page': '2'});
    });

    test('an empty action submits back to the page', () {
      final form =
          _page(
            '<form method="post"><input name="a" value="1">'
            '</form>',
          ).form()!;
      expect(form.action, Uri.parse('https://example.com/login'));
    });

    test('a multipart form refuses rather than sending the wrong encoding', () {
      expect(
        () => _page().form('form.upload')!.body,
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            contains('multipart/form-data'),
          ),
        ),
      );
    });
  });

  group('finding a form', () {
    test('any selector that names it works', () {
      expect(_page().form('#login'), isNotNull);
      expect(_page().form('form[action="/session"]'), isNotNull);
      expect(_page().form('form:has(input[type=password])'), isNotNull);
    });

    test('a selector naming a wrapper finds the form inside it', () {
      expect(_page().form('#panel')!.element.attributes['id'], 'login');
    });

    test('the default takes the first form on the page', () {
      expect(_page().form()!.element.attributes['id'], 'login');
    });

    test('a page with no form reports none rather than throwing', () {
      expect(_page('<p>nothing here</p>').form(), isNull);
      expect(_page().form('#absent'), isNull);
    });
  });

  group('sending a form', () {
    late HttpServer server;
    late String base;
    final seen = <String>[];

    setUp(() async {
      seen.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((fetch) async {
        final body = await utf8.decoder.bind(fetch).join();
        seen.add('${fetch.method} ${fetch.uri} $body');
        fetch.response.headers.contentType = ContentType.html;
        if (fetch.uri.path == '/login') {
          fetch.response
            // Set through the header: this library exports a `Cookie` of its
            // own, which shadows `dart:io`'s for any file importing both.
            ..headers.add('set-cookie', 'sid=session-1; Path=/')
            ..write('''
              <form id="login" action="/session" method="post">
                <input type="hidden" name="csrf" value="tok-123">
                <input type="text" name="user">
              </form>
            ''');
        } else {
          final fields = Uri.splitQueryString(body);
          fetch.response.write(
            '<h1>${fields['user']} in with ${fields['csrf']}</h1>'
            '<p>${fetch.headers.value('cookie')}</p>',
          );
        }
        await fetch.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    test('send posts it and carries a session along', () async {
      final session = Fetcher(session: true);
      addTearDown(session.close);

      final page = await session.get('$base/login'.url);
      final home = await page
          .form('#login')!
          .fill({'user': 'me'})
          .send(client: session);

      expect(home.$('h1').text, 'me in with tok-123');
      // The cookie the login page set came back with the submission.
      expect(home.$('p').text, contains('sid=session-1'));
      expect(seen.last, startsWith('POST /session'));
    });

    test('submit schedules it on the crawl that found it', () async {
      final landed = <String>[];

      final stats = await net
          .crawl<String>('$base/login')
          .tag('home', (res) => landed.add(res.$('h1').text))
          .run(
            (res) => res.submit(
              res.form('#login')!..fill({'user': 'crawler'}),
              tag: 'home',
              meta: [Slot<String>('from')('login')],
            ),
          );

      expect(landed, ['crawler in with tok-123']);
      expect(stats.completed, 2);
      expect(seen.last, contains('user=crawler'));
    });

    test('two submissions of one form are two fetches, not one', () async {
      final searches = <String>[];

      await net
          .crawl<String>('$base/login')
          .tag('result', (res) => searches.add(res.fetch.url.toString()))
          .run((res) {
            final form = res.form('#login')!;
            res.submit(form..fill({'user': 'a'}), tag: 'result');
            res.submit(res.form('#login')!..fill({'user': 'b'}), tag: 'result');
          });

      // De-duplication accounts for the body, so the same URL twice with
      // different fields is two pages.
      expect(searches, hasLength(2));
    });
  });
}
