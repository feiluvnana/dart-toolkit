# Forms (`Form`)

The other half of reading a page. `res.parse(format.html)('input').value` already reads a control the way a browser would submit it; `Form` collects every control on a `<form>`, lets a script override the two it cares about, and works out where the result goes.

That difference matters because of what a real form carries: a CSRF token, a session id, a dozen hidden inputs, the options already selected. Rebuilding those by hand is what makes a login script break every time the page changes.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final session = Fetcher(session: true);
  final page = await session.get('https://example.com/login'.url);

  final home = await page.parse(format.html).form('#login')!
      .at(page.url)
      .fill({'user': 'me', 'pass': 'secret'})
      .send(client: session);

  print(home.parse(format.html)('h1').text);
}
```

---

## 1. Finding one

Finding a form is reading a page, so it hangs off the cursor rather than off
the response — `net` does not parse. `Markup.form(selector)` returns the first
form the selector matches, or `null` when the page has none:

```dart
final page = res.parse(format.html);

page.form();                                   // the first form on the page
page.form('#login');                           // by id
page.form('form[action\$="/search"]');          // by action
page.form('form:has(input[type=password])');   // by what it contains
```

A cursor has no idea what URL its markup came from, so a form that submits to a
relative `action` needs `at` before it is sent — and says so, loudly, rather
than resolving against `localhost`:

```dart
page.form('#login')!.at(res.url).fill({'user': 'me'}).send();
```

Inside a crawl, `res.submit(form)` calls `at` for you.

The selector is a full jQuery selector, so a form is namable by whatever distinguishes it. When it names something that is *not* a form — an id on a wrapping `<div>`, say — the first form inside it is used, so both of these find the same form:

```html
<div id="panel"><form id="login">…</form></div>
```

```dart
page.form('#panel');   // the form inside it
page.form('#login');   // the form itself
```

A page with no form reports `null` rather than throwing, so `page.form('#login')?.fill(...)` is a safe thing to write against a page that may have logged you in already.

---

## 2. What it collects

`fields` holds the *successful controls*, as HTML calls them — what a browser would send if you pressed Enter:

```dart
final form = page.form('#login')!;
form.fields;
// {csrf: tok-123, user: , remember: yes, plan: pro, lang: fr, do: login}
```

| Control | Submitted as |
| :--- | :--- |
| `<input>` with a value | its value |
| `<input>` with none | the empty string — a text field still submits |
| `<input type=checkbox\|radio>` | its value, and only when ticked |
| `<select>` | the selected option's value, or its text when it has none |
| `<textarea>` | its text |
| the first named `<button type=submit>` | its value — the one Enter presses |
| `<input type=file>` | nothing: no file is named on the page |
| `<input type=reset\|button\|image>` | nothing |
| anything `disabled`, or with no `name` | nothing |

Values come from the same reader as `Markup.value`, so what a form submits and what `res.parse(format.html)('select').value` reports can never drift apart.

Two controls sharing one name — a checkbox group — keep the last, as `Body.form` does.

---

## 3. Filling it in

`fill` overrides the names you pass and leaves the rest of the page's own values alone. It returns the form, so filling and sending are one expression:

```dart
page.form('#login')!
    .at(res.url)
    .fill({'user': user, 'pass': pass})
    .send();
```

Names the form does not carry are added, which is how an API that expects a field the HTML does not render still gets one:

```dart
form.fill({'redirect': '/dashboard'});
```

`fields` itself is unmodifiable — `fill` is the one way in, so a form cannot be changed behind its own back.

---

## 4. Where it goes

```dart
form.action;   // the form's action, resolved against the page `at` named
form.method;   // HttpMethod.post for method="post", else HttpMethod.get
form.url;      // where the request goes, fields included for a GET
form.body;     // Body.form(fields), or null for a GET
```

An empty or missing `action` submits back to the page itself. A `GET` carries its fields in the query and *replaces* whatever query the action already had — both of which are what a browser does:

```dart
// <form class="search" action="/search?stale=1">
page.form('form.search')!.at(res.url).fill({'q': 'widgets'}).url;
// https://example.com/search?q=widgets
```

A form declaring `enctype="multipart/form-data"` — one built to upload a file — throws `UnsupportedError` from `body` rather than sending url-encoded fields the server cannot parse. Build that request yourself with `net.http.post`.

---

## 5. Sending it

Two ways, because there are two situations.

**Standalone**, with `send`. Pass the client that fetched the page when it holds a session, so the cookies that came with the form go back with it:

```dart
final session = Fetcher(session: true);
final res = await session.get(loginUrl);
final home = await res.parse(format.html).form('#login')!
    .at(res.url)
    .fill({'user': user, 'pass': pass})
    .send(client: session);
```

Without `client` the shared `net.http` sends it. `headers` and `timeout` work as they do on any request; a `Referer` naming the page `at` was given is set for you.

**Inside a crawl**, with `submit`, which schedules the request on the engine instead of fetching it here and now:

```dart
await net.crawl<String>('https://example.com/login')
    .tag('home', (res) {
      for (final row in res.parse(format.html).find('.item').texts) {
        res.emit(row);
      }
    })
    .run((res) => res.submit(
          res.parse(format.html).form('#login')!
            ..fill({'user': user, 'pass': pass}),
          tag: 'home',
        ));
```

Everything `follow` does still applies: the `Referer` is set, `depth` grows by one, and de-duplication accounts for the body — so the same search form submitted with two different terms is two pages, not one.

`submit` takes the same `tag`, `meta`, `headers`, `priority` and `dedupe` as `follow`.

---

## 6. A form the page did not carry

`Form` can be built directly from any parsed `<form>` element. Pass `page`, or a relative `action` has nothing to resolve against:

```dart
final element = format.html.parse(markup).find('form').elements.first!;
final form = Form(element, page: 'https://example.com/login'.url);
```

---

## 7. Paging through a form

Because `submit` goes through the engine, a paginated POST is a stage that queues its own next page:

```dart
await net.crawl<Map<String, Object?>>(searchUrl)
    .tag('page', (res) {
      final page = res.parse(format.html);
      for (final row in page.find('.result').elements.list) {
        res.emit({'title': row.query.find('h3').text});
      }
      final next = page.form('form.pager');
      if (next != null && !page.find('.next').empty) {
        res.submit(next..fill({'page': '${res.depth + 2}'}), tag: 'page');
      }
    })
    .run((res) => res.submit(
        res.parse(format.html).form('form.search')!..fill({'q': term}),
        tag: 'page'));
```

---

## See also

- [docs/http.md](http.md) — the client, sessions and cookies
- [docs/crawl.md](crawl.md) — `follow`, tags and the engine
- [docs/html.md](html.md) — `value`, `values` and the rest of the reading side
