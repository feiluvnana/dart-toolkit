import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('jQuery-like Selector \$()', () {
    const sampleHtml = '''
    <div id="container" class="main-box">
      <h1 class="title">Album Title</h1>
      <ul class="track-list">
        <li class="track" data-id="1">
          <span class="num">01.</span>
          <a href="/track/1" class="link">Track One</a>
          <span class="duration">03:45</span>
        </li>
        <li class="track" data-id="2">
          <span class="num">02.</span>
          <a href="/track/2" class="link">Track Two</a>
          <span class="duration">04:12</span>
        </li>
        <li class="track bonus" data-id="3">
          <span class="num">03.</span>
          <a href="https://example.com/bonus" class="link">Bonus Track</a>
          <span class="duration">05:00</span>
        </li>
      </ul>
      <div class="footer">
        <p>Copyright 2026</p>
      </div>
    </div>
    ''';

    test('parses HTML string directly into QueryResult', () {
      final query = $(sampleHtml);
      expect(query.isNotEmpty, isTrue);
      expect(query.find('.title').text, equals('Album Title'));
    });

    test('queries by CSS selector on HTML string context', () {
      final tracks = $('.track', sampleHtml);
      expect(tracks.length, equals(3));
      expect(tracks.first.find('.num').text, equals('01.'));
      expect(tracks.last.find('.num').text, equals('03.'));
    });

    test('text, texts, and html extraction', () {
      final doc = $(sampleHtml);
      expect(doc.find('h1').text, equals('Album Title'));
      expect(doc.find('.track a').texts, equals(['Track One', 'Track Two', 'Bonus Track']));
      expect(doc.find('.footer p').text, equals('Copyright 2026'));
      expect(doc.find('.footer').html.trim(), equals('<p>Copyright 2026</p>'));
    });

    test('attributes extraction with attr and attrs', () {
      final doc = $(sampleHtml);
      expect(doc.find('.track').first.attr('data-id'), equals('1'));
      expect(doc.find('.track').attrs('data-id'), equals(['1', '2', '3']));
      expect(
        doc.find('.track a').attrs('href'),
        equals(['/track/1', '/track/2', 'https://example.com/bonus']),
      );
    });

    test('traversal: find, children, parent, filter, and eq', () {
      final doc = $(sampleHtml);

      // eq
      expect(doc.find('.track').eq(1).find('.link').text, equals('Track Two'));

      // filter
      final bonus = doc.find('.track').filter((el) => el.classes.contains('bonus'));
      expect(bonus.length, equals(1));
      expect(bonus.find('.link').text, equals('Bonus Track'));

      // hasClass
      expect(bonus.hasClass('bonus'), isTrue);
      expect(bonus.hasClass('non-existent'), isFalse);

      // children
      final listChildren = doc.find('.track-list').children();
      expect(listChildren.length, equals(3));

      // parent
      final parent = doc.find('.track').parent();
      expect(parent.hasClass('track-list'), isTrue);
    });

    test('extensions on String and Element', () {
      final q = sampleHtml.$('.title');
      expect(q.text, equals('Album Title'));

      final elem = q.firstOrNull;
      expect(elem, isNotNull);
      expect(elem!.asQuery.text, equals('Album Title'));
    });
  });
}
