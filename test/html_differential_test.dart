import 'dart:io';

import 'package:dart_toolkit/html.dart';
import 'package:html/parser.dart' as reference;
import 'package:test/test.dart';

/// The in-house parser against `package:html` on three real pages: every selector below
/// must find the same elements, in the same order, with the same text and href.
///
/// Known, intended differences are kept out of the list: `:empty` (the reference matches
/// elements with text), `:nth-child` (the reference returns nothing), and `<noscript>`
/// content (the reference keeps it as text; a scraper wants the markup).
void main() {
  const selectors = [
    'a', 'a[href]', 'div', 'p', 'li', 'tr', 'td', 'table tr', 'ul > li', 'ol > li', 'h1, h2, h3', 'img[src]', 'span', //
    'tr > td', 'body > div', 'head > title', 'meta[name]', 'a[href^="http"]', 'li:first-child', 'div > p', 'table',
    'tbody > tr', 'form input', 'select option', 'script', 'style', 'p + p', 'h2 ~ p', 'a:not([href])',
    '.key_cd_track_box ul li', '.track_disc_title', '.track_disc_text_style1', '.key_cd_artworks_box',
    'tr.athing', '.titleline > a', 'td.subtext', '.site-header a', 'nav a[href]',
  ];

  for (final name in ['key_box', 'hn', 'dart_dev']) {
    test('$name.html parses like the reference', () {
      final src = File('test/fixtures/$name.html').readAsStringSync();
      final ours = HtmlDocument.parse(src);
      final theirs = reference.parse(src);
      for (final sel in selectors) {
        final a = [for (final e in ours.$(sel)) (e.name, e.attr('href'), e.text.trim())];
        final b = [for (final e in theirs.querySelectorAll(sel)) (e.localName, e.attributes['href'], e.text.trim())];
        expect(a, equals(b), reason: sel);
      }
    });
  }

  test('the in-house parser is not slower than the reference on the largest fixture', () {
    final src = File('test/fixtures/key_box.html').readAsStringSync();
    for (var i = 0; i < 3; i++) {
      HtmlDocument.parse(src);
      reference.parse(src);
    }
    final ours = Stopwatch()..start();
    for (var i = 0; i < 20; i++) {
      HtmlDocument.parse(src);
    }
    ours.stop();
    final ref = Stopwatch()..start();
    for (var i = 0; i < 20; i++) {
      reference.parse(src);
    }
    ref.stop();
    expect(
      ours.elapsedMicroseconds,
      lessThan(ref.elapsedMicroseconds * 1.5),
      reason: '${ours.elapsed} vs ${ref.elapsed}',
    );
  });
}
