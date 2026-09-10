// Sign in, then submit the form the page came with.
//
//   dart run example/form.dart
//
// `res.form(...)` collects a form's controls the way a browser would submit
// them: the hidden inputs, the CSRF token, the ticked boxes, the option
// already selected. A script overrides the two fields it knows about and
// sends the rest back untouched — which is what carries a token through a
// login without hand-copying it.

import 'dart:convert';

import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final log = system.console.logger;

  // ------------------------------------------------------------ reading one
  final page = Reply.text(_login, url: 'https://shop.test/login'.url);
  final form = page.form('#login')!;

  // Everything the page already carried, without asking for it.
  log.info('Fields: ${form.fields}');
  log.info('Sends:  ${form.method.wire} ${form.action}');

  form.fill({'user': 'alice', 'pass': 'hunter2'});
  log.ok('Body:   ${utf8.decode(form.body!.bytes())}');

  // A GET form puts its fields in the query instead of a body.
  final search = page.form('form.search')!..fill({'q': 'keyboard'});
  log.ok('Search: ${search.url}');

  // Off a live page this is the whole login: hand `send` the client that
  // fetched the form and its session cookies go back with it.
  //
  //   final session = Fetcher(session: true);
  //   final home = await (await session.get(url)).form('#login')!
  //       .fill({'user': user, 'pass': pass})
  //       .send(client: session);

  // ---------------------------------------------------------- inside a crawl
  // `res.submit(form)` schedules the submission on the engine instead, so the
  // answer reaches a tagged handler like any other page: the method, the URL
  // and the body all come from the form.
  final greeting =
      await net
          .crawl<String>('https://shop.test/login')
          .downloader(MapDownloader<String>(_fixtures))
          .route(RegExp(r'/login$'), (res) {
            final login = res.form('#login')!.fill({
              'user': 'alice',
              'pass': 'hunter2',
            });
            res.submit(login, tag: 'home');
          })
          .tag('home', (res) => res.emit(res.$('.welcome').text))
          .collect();

  log.ok('Signed in: ${greeting.single}');
}

const _login = '''
<form id="login" action="/session" method="post">
  <input type="hidden" name="csrf" value="tok-7f3a">
  <input name="user">
  <input type="password" name="pass">
  <input type="checkbox" name="remember" value="yes" checked>
  <select name="realm">
    <option value="staff">Staff</option>
    <option value="shop" selected>Shop</option>
  </select>
  <button type="submit" name="do" value="signin">Sign in</button>
</form>
<form class="search" action="/search"><input name="q"></form>
''';

// `MapDownloader` keys take an optional method, so the GET that serves the
// form and the POST that answers it are two different fixtures.
const _fixtures = <String, String>{
  'GET /login': _login,
  'POST /session': '<p class="welcome">Welcome back, alice.</p>',
};
