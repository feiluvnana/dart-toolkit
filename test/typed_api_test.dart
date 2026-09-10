/// The 2.0.0 typed core: `Slot`/`Meta`, and everything else that replaced an
/// `Object?` in a public signature. Each group names the thing that used to be
/// untyped and what it is now.
library;

import 'dart:convert';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

const _name = Slot<String>('name');
const _track = Slot<int>('track');
const _ratio = Slot<double>('ratio');
const _tags = Slot<List<Object?>>('tags');
const _since = Slot<DateTime>.coded(
  'since',
  read: _readTime,
  write: _writeTime,
);

DateTime? _readTime(Object? raw) =>
    raw is String ? DateTime.tryParse(raw) : null;
Object? _writeTime(DateTime value) => value.toIso8601String();

void main() {
  group('Slot', () {
    test('reads a value of its own type and refuses another', () {
      expect(_name.read('Hey Jude'), 'Hey Jude');
      expect(_name.read(4), isNull);
      expect(_track.read(4), 4);
      expect(_track.read('4'), isNull);
      expect(_tags.read(const ['a', 'b']), ['a', 'b']);
    });

    test('a whole number still reads as a double', () {
      // jsonDecode gives `5` for both `5` and `5.0`, so a Slot<double> that
      // only accepted a double would read back null for half its own values.
      expect(_ratio.read(5), 5.0);
      expect(_ratio.read(5.5), 5.5);
      expect(_ratio.read('5'), isNull);
    });

    test('an absent value reads as null rather than throwing', () {
      expect(_name.read(null), isNull);
    });

    test('coded slots carry a type JSON does not', () {
      final when = DateTime.utc(2026, 3, 1);
      expect(_since.write(when), '2026-03-01T00:00:00.000Z');
      expect(_since.read('2026-03-01T00:00:00.000Z'), when);
      expect(_since.read(17), isNull);
    });

    test('calling a slot builds the entry it writes', () {
      final entry = _name('Hey Jude');
      expect(entry.key, 'name');
      expect(entry.value, 'Hey Jude');
      expect(_since(DateTime.utc(2026)).value, '2026-01-01T00:00:00.000Z');
    });
  });

  group('Meta', () {
    test('round-trips values through their slots', () {
      final meta = Meta([_name('Hey Jude'), _track(4)]);

      expect(meta.get(_name), 'Hey Jude');
      expect(meta.get(_track), 4);
      expect(meta.has(_name), isTrue);
      expect(meta.length, 2);

      meta.delete(_name);
      expect(meta.get(_name), isNull);
      expect(meta.has(_name), isFalse);
    });

    test('a slot reading a key another slot wrote gets null, not a crash', () {
      final meta = Meta([_name('Hey Jude')]);
      expect(meta.get(const Slot<int>('name')), isNull);
    });

    test('raw is the map underneath, and survives jsonEncode', () {
      final meta = Meta([
        _name('Hey Jude'),
        _track(4),
        _since(DateTime.utc(2026)),
      ]);
      final restored = Meta.of(
        (jsonDecode(jsonEncode(meta.raw)) as Map).cast<String, Object?>(),
      );

      expect(restored.get(_name), 'Hey Jude');
      expect(restored.get(_track), 4);
      expect(restored.get(_since), DateTime.utc(2026));
    });

    test('entries spread one bag into another', () {
      final first = Meta([_name('Hey Jude')]);
      final second = Meta([...first.entries, _track(4)]);

      expect(second.get(_name), 'Hey Jude');
      expect(second.get(_track), 4);
    });
  });

  group('Fetch.meta', () {
    test('carries typed context through a crawl and its resume file', () async {
      final seen = <String?>[];

      await net
          .crawl<String>('https://music.test/album'.url)
          .downloader(
            MapDownloader<String>({
              'https://music.test/album':
                  '<a href="/song/1">One</a><a href="/song/2">Two</a>',
              'https://music.test/song/1': '<h1>One</h1>',
              'https://music.test/song/2': '<h1>Two</h1>',
            }),
          )
          .tag('song', (res) => seen.add(res.meta.get(_name)))
          .run((res) {
            for (final a in res.parse(format.html).find('a').elements.list) {
              res.follow(a.attr('href')!, tag: 'song', meta: [_name(a.text)]);
            }
          });

      expect(seen, ['One', 'Two']);
    });

    test('survives the JSON round trip a resume file makes it take', () {
      final fetch = Fetch<String>(
        Uri.parse('https://example.com/'),
        tag: 'detail',
        meta: [_name('Widget'), _track(3)],
      );

      final copy = Fetch<String>.fromJson(
        jsonDecode(jsonEncode(fetch.toJson())) as Map<String, Object?>,
      );

      expect(copy.meta.get(_name), 'Widget');
      expect(copy.meta.get(_track), 3);
    });
  });

  group('records instead of Map<String, Object?>', () {
    final page = Reply.text('''
      <div id="product">
        <h1>Wool Coat</h1>
        <span class="price">\$89.00</span>
        <div class="seller">
          <span class="name">Acme</span><span class="rating">4.5</span>
        </div>
        <div class="variant" data-sku="A1">
          <span class="name">Small</span><span class="qty">3</span>
        </div>
        <div class="variant" data-sku="A2">
          <span class="name">Large</span><span class="qty">7</span>
        </div>
      </div>
    ''');

    test('all builds one typed record per match', () {
      final variants = page
          .parse(format.html)
          .all(
            '.variant',
            (row) => (
              name: row.find('.name').text,
              sku: row.attr('data-sku'),
              qty: row.pick(Field.text('.qty').when(int.tryParse)),
            ),
          );

      // The static type is the point: no cast reaches any of these fields.
      expect(variants.count(), 2);
      expect(variants.first!.name, 'Small');
      expect(variants.first!.sku, 'A1');
      expect(variants.first!.qty, 3);
      expect(variants.last!.qty, 7);
    });

    test('one builds a record for a section a page has at most one of', () {
      final seller = page
          .parse(format.html)
          .one(
            '.seller',
            (s) => (
              name: s.find('.name').text,
              rating: s.pick(Field.text('.rating').when(util.text.number)),
            ),
          );

      expect(seller?.name, 'Acme');
      expect(seller?.rating, 4.5);
      expect(
        page.parse(format.html).one('.missing', (s) => s.find('x').text),
        isNull,
      );
    });

    test('a whole page reads as one nested record', () {
      final product = (
        title: page.parse(format.html).find('h1').text,
        price: page
            .parse(format.html)
            .pick(Field.text('.price').when(util.text.number)),
        variants: page
            .parse(format.html)
            .all(
              '.variant',
              (row) => (
                name: row.find('.name').text,
                sku: row.attr('data-sku'),
              ),
            ),
      );

      expect(product.title, 'Wool Coat');
      expect(product.price, 89.0);
      expect(product.variants.to((v) => v.sku).list, ['A1', 'A2']);
    });

    test('all and pick see matches at the top level of the body', () {
      // `page.$` holds the body's *children*, so routing `all` through `find`
      // — strict descendants — missed anything sitting at the top level. The
      // first fixture for this happened to wrap everything in a div, which
      // hid it.
      final flat = Reply.text(
        '<h1>T</h1>'
        '<div class="variant" data-sku="A1"><span class="name">S</span></div>'
        '<div class="variant" data-sku="A2"><span class="name">L</span></div>',
      );

      expect(
        flat
            .parse(format.html)
            .all('.variant', (row) => row.attr('data-sku'))
            .list,
        ['A1', 'A2'],
      );
      expect(
        flat
            .parse(format.html)
            .one('.variant', (row) => row.find('.name').text)
            ?.trim(),
        'S',
      );
      // And pick reads the document root, so a page cursor and the same markup
      // parsed straight from a string agree.
      expect(flat.parse(format.html).pick(Field.text('h1')), 'T');
      expect(
        format.html.parse(flat.body).pick(Field.text('h1')),
        flat.parse(format.html).pick(Field.text('h1')),
      );
    });

    test('all scopes to the row, not the document', () {
      // The bug this shape exists to prevent: a nested read that quietly
      // matched every `.name` on the page instead of the row's own.
      final names = page
          .parse(format.html)
          .all('.variant', (row) => row.find('.name').texts.list);
      expect(names.list, [
        ['Small'],
        ['Large'],
      ]);
    });
  });

  group('Field.map and Field.when', () {
    test('adjusts what a field that already works read', () {
      final page = Reply.text(
        '<span class="price">\$1,234.50</span><b>a</b><b>b</b>',
      );

      expect(
        page
            .parse(format.html)
            .pick(Field.text('.price').when(util.text.number)),
        1234.5,
      );
      expect(
        page
            .parse(format.html)
            .pick(Field.texts('b').map((rows) => rows.length)),
        2,
      );
      // `map` sees the null; `when` is not called at all for one.
      expect(
        page
            .parse(format.html)
            .pick(Field.text('.gone').map((t) => t ?? 'unknown')),
        'unknown',
      );
      expect(
        page
            .parse(format.html)
            .pick(Field.text('.gone').when(util.text.number)),
        isNull,
      );
      // Chains, because the result is a Field like any other.
      expect(
        page
            .parse(format.html)
            .pick(
              Field.text('.price').when(util.text.number).map((n) => n! * 2),
            ),
        2469.0,
      );
    });
  });

  group('Settled instead of a nullable tuple', () {
    test(
      'Done carries a non-nullable value, Broke carries the error',
      () async {
        final pool = Pool<int>(size: 2);
        final outcomes = await pool.settle([1, 0, 2], (n) async {
          if (n == 0) throw StateError('division by zero');
          return 10 ~/ n;
        });

        final read = [
          for (final outcome in outcomes.list)
            switch (outcome) {
              // `value` is `int` here, not `int?`: that is the whole point.
              Done(:final int value) => 'ok:$value',
              Broke(:final error) => 'bad:${(error as StateError).message}',
            },
        ];

        expect(read, ['ok:10', 'bad:division by zero', 'ok:5']);
        expect(outcomes.to((o) => o.ok).list, [true, false, true]);
        expect(outcomes.list[1].value, isNull);
        expect((outcomes.list[1] as Broke<int>).stack, isNotNull);
      },
    );

    test('PoolFailure keeps its results typed', () async {
      final pool = Pool<int>(size: 2);
      pool.on.error((_, _, _) {});

      try {
        await pool.run([1, 2, 3], (n) async {
          if (n == 2) throw StateError('no');
          return n * 10;
        });
        fail('expected PoolFailure');
      } on PoolFailure<int, int> catch (failure) {
        // `List<int?>`, not `List<dynamic>` — this used to need a cast.
        final List<int?> results = failure.results;
        expect(results, [10, null, 30]);
        expect(failure.failures.single.item, 2);
      }
    });
  });

  group('gather', () {
    final pages = {
      'https://site.test': '<h1>One</h1><h1>Two</h1><a href="/b">next</a>',
      'https://site.test/b': '<h1>Three</h1>',
    };

    test('infers the item type from what the mapper returns', () async {
      // `Never` because this crawl emits nothing; `R` is String, taken from
      // the mapper, where collect can only learn T from an emit buried inside
      // a closure.
      final titles = await net
          .crawl<Never>('https://site.test'.url)
          .downloader(MapDownloader(pages))
          .gather((page) => page.parse(format.html).find('h1').texts.list);

      expect(titles, isA<Sequence<String>>());
      expect(titles.list, ['One', 'Two']);
    });

    test('returning nothing for a page filters it out', () async {
      final long = await net
          .crawl<Never>('https://site.test'.url)
          .downloader(MapDownloader(pages))
          .gather(
            (page) =>
                page
                    .parse(format.html)
                    .find('h1')
                    .texts
                    .keep((t) => t.length > 3)
                    .list,
          );

      expect(long.empty, isTrue);
    });

    test('a record per page reads as one expression', () async {
      final rows = await net
          .crawl<Never>('https://site.test'.url)
          .downloader(MapDownloader(pages))
          .gather(
            (page) => [
              (
                url: page.url.path,
                titles: page.parse(format.html).find('h1').count,
              ),
            ],
          );

      expect(rows.sole!.titles, 2);
    });
  });
}
