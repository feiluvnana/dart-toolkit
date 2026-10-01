## scrape / chrome

### Upgrading

| before | after |
|---|---|
| `import 'package:dart_toolkit/dart_toolkit.dart';` for `ChromeClient` | add `import 'package:dart_toolkit/chrome.dart';` (Chrome is its own library, outside the barrel) |
| `ChromeClient.attach(port: 9222)` | `ChromeClient.connect(port: 9222)`: it joins the browser already there, and starts one only when none is |
| `chrome.isNewBrowser` | — (run `connect` against a browser you started, or `launch` one) |
| `page.reload()` | `page.goto(page.url)` |
| `ctx.response.html.$('a.next')` | `ctx.html.$('a.next')` |
| `ctx.resolve(a.attr('href'))` / `song.resolve(page.$('a.f').attr('href'))` | `ctx.resolve(a)` / `song.resolve(page.$('a.f'))` |
| `for (final u in api.json['next'].to<List<String>>()) ctx.follow(u)` | `ctx.follow(api.json['next'])` (also any `Iterable` of `Uri`/`String`/`Element`; a JSON `null` schedules nothing) |
| a hand-kept `seen` set for URLs that differ by a session parameter | `ctx.canonical = (u) => u.replace(queryParameters: {...u.queryParameters}..remove('sid'))` in `onInit` |
| `for (var i = 0; i < 50; i++) await page.scroll(times: 1)` + a height check | `await page.scroll(toEnd: true)` |

`bin/`: books.dart +1 line (the `chrome.dart` import); keybox.dart unchanged in length,
`ctx.response.html` → `ctx.html` twice and one `.attr('href')` gone from a `resolve`.

### Removed

- `ChromeClient.attach` (public). `connect` was already the door to a running browser; it now
  joins it directly instead of going through a second public constructor.
- `ChromeClient.isNewBrowser`, and the private `_started` it read.
- `ChromePage.reload` — `goto(page.url)`.
- The profile-lock check before launch; the one after a failed start (which names the holder)
  is the only one, and covers the same case.
- `_Jar._of` in `http/cookies.dart` (its only caller was Chrome), `_howToStart`, `_untilQuiet`,
  `_keyOf`, `_Item.key`; the three copies of the capped-read loop in the crawl are one
  `_readCapped`.

### Added

- `package:dart_toolkit/chrome.dart`: `ChromeClient`, `ChromePage`, `Device`, `Resource`,
  `ChromeWait`, `Dialog`, in `lib/src/chrome/{client,page,browser}.dart`. It uses `http` only
  through `http.dart`; `http`'s public surface did not change for it.
- `ResponseContext.html`.
- `HookContext.resolve` takes an `Element`, or `Elements` (the first match), by `href` else
  `src`; a `StateError` names a missing one.
- `HookContext.follow` takes any `Iterable` of `Uri`/`String`/`Element`, and a `JsonDocument`
  holding a string, a list or `null`.
- `InitContext.canonical`: applied to the visited check only (seeds, follows, redirect hops and
  the URL a client answered from); the request still goes to the URL that was followed.
- `follow` and `resolve` honour the page's `<base href>` (`HtmlDocument.base`) once the
  response has been read as HTML; a page never read as HTML is not parsed for it.
- `ChromePage.scroll(toEnd: true)`: until the height stops growing, capped at the client's
  `timeout`.
- `ChromePage.cookies()` is documented as the whole browser's jar with `expires` kept (it was
  already read through `Storage.getCookies` after phase 2); tested across two origins.
- `ChromeClient.connect` gets its first test: the second run joins the browser the first
  started.

### Faster

All back-to-back on one machine, alternating order; the machine was shared with other agents'
test runs, so the medians are noisy and the paired deltas are the numbers to read.

- **`import 'package:dart_toolkit/http.dart'` (S-2): −32 ms** paired median over 20 alternating
  rounds (median 840 → 820 ms, minimum 730 → 709 ms). An earlier 10-round run gave −37 ms.
  Measured with both trees at `0b10471` plus this change only.
- **A render with a `waitFor` or `script` (P-CHR-1): 308–336 → 261–263 ms** per page on a
  2.7 MB DOM (3 alternating process pairs, median of 10 renders each). `goto` reads the DOM on
  arrival only for a 403/429/503, which might be an interstitial; otherwise the render reads it
  once, after the directives.
- **`waitForDownload` (P-CHR-3): 205–217 → 8 ms** per small download (same runs, median of 10).
  The wait ends on the `completed` event; a resettable idle `Timer` replaces the 200 ms poll.
  Chrome lets one page start only about ten downloads a second; the old poll kept a tight loop
  under that by accident. The doc comment now says so.
- **P-CHR-2:** a raw request asks Chrome for the cookies of its own URL through an open tab
  (`Network.getCookies {urls:[url]}`), not the browser's whole jar; `Network` is not a browser
  domain, so with no tab open it falls back to `Storage.getCookies` filtered here. Not timed.
- **P-CHR-4 / CHR-8:** `Runtime.enable` and `Target.setAutoAttach` only on a tab's first
  `frame()` (done in phase 2; tidied into one memoised `_frames` future).
- **P-SCR-1:** under `pages:`, sitemap pages wait in a URL backlog and enter the frontier only
  while `pages + inFlight + queued` is under the budget; no further sitemap is read until the
  backlog is used. A page robots drops is made up from the backlog (tested: 30 of 30 with a
  third of the sitemap disallowed, and fewer than 100 of 800 entries ever reached the frontier).
- **P-SCR-2:** each host keeps its parsed `_RobotsTxt` (groups + sitemaps), not up to 512 KiB
  of text; a second user-agent reads the groups again, not the file.
- **P-SCR-3:** `fetchOwn` drains a non-2xx without reading it, drains a send that timed out,
  and cuts with `chunk.sublist` instead of copying the chunk first.

### Verified (phase 2 already fixed them)

CHR-1 through CHR-7 and CHR-9 are in the code with tests; nothing more was needed.

### Skipped

- **CHR-10, the `Http.scope(cookies:)` half.** `Http.scope(cookies:)` is a `bool`, so a
  `List<Cookie>` cannot feed it without changing `http`'s scope API, which is not this area.
  Proposal for the integrator/http: `Http.scope(cookies: true)` stays, and the jar can be
  seeded — e.g. `Http.scope(cookies: true, jar: await page.cookies())`, or a `cookies:` that takes
  `Iterable<Cookie>` with `const []` for an empty jar. `_Jar` would need a `store(Cookie)` that
  keeps `domain`/`hostOnly`/`expires`.
- **A test that `Runtime.enable` is not on before `frame()`.** The console-serialises-the-error
  probe no longer detects it in Chrome 154, and the CDP state is not observable from a public
  API.
- **`attach` → private `_join`.** `connect` was its only caller, so it builds the client directly;
  a one-caller private wrapper would be a name for nothing.

### CONVENTIONS

- *Own namespaces*: add `package:dart_toolkit/chrome.dart` (`ChromeClient`, `ChromePage`,
  `Device`, `Resource`, `ChromeWait`, `Dialog`) beside `ffi`, with the reason "a third of `http`'s
  source; −32 ms on every `http` import". The *why* differs from `ffi`'s (startup, not short
  names), so the section's rule could read "not in the barrel when its names are short *or* its
  compile cost falls on programs that never use it".
- *Illegal states are not representable*: `ctx.follow` now takes "a link, a `Uri`, an element,
  any iterable of them, or a `JsonDocument` holding them" — update that sentence.
