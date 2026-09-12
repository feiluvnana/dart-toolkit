/// The typed core: records, `Field`, `Settled`, and everything else that replaced
/// an `Object?` in a public signature.
library;

import 'dart:convert';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('Fetch.meta', () {
    test('carries typed context through a crawl and its resume file', () async {
      final seen = <String?>[];

      const pages = {
        'https://music.test/album':
            '<a href="/song/1">One</a><a href="/song/2">Two</a>',
        'https://music.test/song/1': '<h1>One</h1>',
        'https://music.test/song/2': '<h1>Two</h1>',
      };

      await Http.crawl(
            [Fetch('https://music.test/album'.url)],
            (res) => switch (res.fetch.tag) {
              null =>
                res
                    .parse(Codec.html)
                    .$('a')
                    .elements
                    .map(
                      (a) => res.follow(
                        a.attributes['href']!,
                        tag: 'song',
                        meta: [('name', a.text)],
                      ),
                    ),
              _ => const <Fetch>[],
            },
          )
          .using(
            (fetch) async =>
                Reply.text(pages['${fetch.url}'] ?? '', fetch: fetch),
          )
          .flow
          .where((res) => res.fetch.tag == 'song')
          .forEach((res) => seen.add(res.fetch.meta['name'] as String?));

      expect(seen, ['One', 'Two']);
    });

    test('survives the JSON round trip a resume file makes it take', () {
      final fetch = Fetch(
        Uri.parse('https://example.com/'),
        tag: 'detail',
        meta: [('name', 'Widget'), ('track', 3)],
      );

      final copy = Fetch.fromJson(
        jsonDecode(jsonEncode(fetch.toJson())) as Map<String, Object?>,
      );

      expect(copy.meta['name'], 'Widget');
      expect(copy.meta['track'], 3);
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
          .parse(Codec.html)
          .all(
            '.variant',
            (row) => (
              name: row.$('.name').text,
              sku: row.attr('data-sku'),
              qty: row.pick(Field.text('.qty').when(int.tryParse)),
            ),
          );

      // The static type is the point: no cast reaches any of these fields.
      expect(variants.length, 2);
      expect(variants.first.name, 'Small');
      expect(variants.first.sku, 'A1');
      expect(variants.first.qty, 3);
      expect(variants.last.qty, 7);
    });

    test('all plus first builds the record a page has at most one of', () {
      final seller = page
          .parse(Codec.html)
          .all(
            '.seller',
            (s) => (
              name: s.$('.name').text,
              rating: s.pick(Field.text('.rating').when(Text.number)),
            ),
          )
          .firstOrNull;

      expect(seller?.name, 'Acme');
      expect(seller?.rating, 4.5);
      expect(
        page
            .parse(Codec.html)
            .all('.missing', (s) => s.$('x').text)
            .firstOrNull,
        isNull,
      );
    });

    test('a whole page reads as one nested record', () {
      final product = (
        title: page.parse(Codec.html).$('h1').text,
        price: page
            .parse(Codec.html)
            .pick(Field.text('.price').when(Text.number)),
        variants: page
            .parse(Codec.html)
            .all(
              '.variant',
              (row) => (name: row.$('.name').text, sku: row.attr('data-sku')),
            ),
      );

      expect(product.title, 'Wool Coat');
      expect(product.price, 89.0);
      expect(product.variants.map((v) => v.sku).toList(), [
        'A1',
        'A2',
      ]);
    });

    test('all and pick see matches at the top level of the body', () {
      final flat = Reply.text(
        '<h1>T</h1>'
        '<div class="variant" data-sku="A1"><span class="name">S</span></div>'
        '<div class="variant" data-sku="A2"><span class="name">L</span></div>',
      );

      expect(
        flat
            .parse(Codec.html)
            .all('.variant', (row) => row.attr('data-sku')),
        ['A1', 'A2'],
      );
      expect(
        flat
            .parse(Codec.html)
            .all('.variant', (row) => row.$('.name').text)
            .firstOrNull
            ?.trim(),
        'S',
      );
      expect(flat.parse(Codec.html).pick(Field.text('h1')), 'T');
      expect(
        Formats.html(flat.body).pick(Field.text('h1')),
        flat.parse(Codec.html).pick(Field.text('h1')),
      );
    });

    test('all scopes to the row, not the document', () {
      final names = page
          .parse(Codec.html)
          .all('.variant', (row) => row.$('.name').texts);
      expect(names, [
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
            .parse(Codec.html)
            .pick(Field.text('.price').when(Text.number)),
        1234.5,
      );
      expect(
        page
            .parse(Codec.html)
            .pick(Field.texts('b').map((rows) => rows.length)),
        2,
      );
      // `map` sees the null; `when` is not called at all for one.
      expect(
        page
            .parse(Codec.html)
            .pick(Field.text('.gone').map((t) => t ?? 'unknown')),
        'unknown',
      );
      expect(
        page
            .parse(Codec.html)
            .pick(Field.text('.gone').when(Text.number)),
        isNull,
      );
      // Chains, because the result is a Field like any other.
      expect(
        page
            .parse(Codec.html)
            .pick(
              Field.text('.price').when(Text.number).map((n) => n! * 2),
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
          for (final outcome in outcomes)
            switch (outcome) {
              // `value` is `int` here, not `int?`: that is the whole point.
              Done(:final int value) => 'ok:$value',
              Broke(:final error) => 'bad:${(error as StateError).message}',
            },
        ];

        expect(read, ['ok:10', 'bad:division by zero', 'ok:5']);
        expect(outcomes.map((o) => o.ok).toList(), [
          true,
          false,
          true,
        ]);
        expect(outcomes[1].value, isNull);
        expect((outcomes[1] as Broke<int>).stack, isNotNull);
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
        // One outcome type across `run`, `settle` and `on.error`.
        final List<Settled<int>> outcomes = failure.outcomes;
        expect(outcomes.map((o) => o.value), [10, null, 30]);

        // Which item broke is the alignment with `items`, not a field on
        // `Broke` — the caller already holds the item.
        final broken = outcomes
            .indexWhere((o) => o is Broke<int>);
        expect(failure.items.toList()[broken], 2);
      }
    });
  });

  group('extraction is downstream, on the flow', () {
    const pages = {
      'https://site.test': '<h1>One</h1><h1>Two</h1><a href="/b">next</a>',
      'https://site.test/b': '<h1>Three</h1>',
    };

    Crawl crawl() => Http.crawl([Fetch('https://site.test'.url)])
      ..using(
        (fetch) async => Reply.text(pages['${fetch.url}'] ?? '', fetch: fetch),
      );

    test('the item type comes from the pipeline, not from the crawl', () async {
      // `gather` existed because `items` could only learn `T` from an emit
      // buried inside a closure. There is no `T` any more: the crawl produces
      // replies, and what a script does with them is its own business.
      final titles = await crawl().flow
          .expand((Reply res) => res.parse(Codec.html).$('h1').texts)
          .toList();

      expect(titles, isA<List<String>>());
      expect(titles, ['One', 'Two']);
    });

    test('returning nothing for a page filters it out', () async {
      final long = await crawl().flow
          .expand(
            (Reply res) => res
                .parse(Codec.html)
                .$('h1')
                .texts
                .where((t) => t.length > 3),
          )
          .toList();

      expect(long.isEmpty, isTrue);
    });

    test('a record per page reads as one expression', () async {
      final rows = await crawl().flow
          .map(
            (Reply res) => (
              url: res.url.path,
              titles: res.parse(Codec.html).$('h1').count,
            ),
          )
          .toList();

      expect(rows.single.titles, 2);
    });
  });
}
