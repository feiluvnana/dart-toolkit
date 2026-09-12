// Walk a site in stages.
//
//   dart run example/crawl.dart
//
// A listing page queues detail pages, each detail page queues its own. The
// whole router is a `switch` on the tag the request carried, which the
// compiler checks; `meta` carries context between stages so a later one never
// re-parses what its parent already knew.
//
// The transport is a function. Drop the `.using(...)` line and the same crawl
// runs against the real site through `net.http`.

import 'package:dart_toolkit/dart_toolkit.dart';

typedef Track = ({String artist, String album, String title});

// Typed keys, declared once and checked at both ends: `artist('Nujabes')` will
// not compile with a number in it, and `res.fetch.meta.read(artist)` hands
// back a String? without a cast.
const artist = Slot<String>('artist');
const album = Slot<String>('album');

void main() async {
  final log = system.console.logger;

  final crawl = net.crawl([Fetch('https://music.test/artists'.url)], _next)
    // A transport is a `Send` — `Future<Reply> Function(Fetch)`. A fixture is
    // a closure over a map; a headless browser is a closure over a page.
    ..using(_fixture)
    // Politeness and scope. Without these a crawl wanders off the site it
    // started on; `perhost` paces each host separately once seeds span more
    // than one.
    ..concurrent(4)
    ..delay(20.ms)
    ..sameHost()
    ..depth(3)
    ..limit(500)
    ..allow(RegExp(r'music\.test/(artists|albums)'))
    ..deny(RegExp(r'\?(sort|filter)='));
  // A crawl that has to survive the real world adds three more:
  //   ..obey('ExampleBot/1.0')      robots.txt, Crawl-delay included
  //   ..resume('crawl.state')       carry on where an interrupt stopped
  //   ..accept(['text/html'])       never hand a PDF to the HTML parser
  // Everything about the *client* — headers, timeout, retries, cap, cache,
  // rate — is set once on the Fetcher handed to `using`.

  // Extraction is downstream, on the flow: the crawl produces replies and the
  // collection vocabulary turns them into whatever this script wanted.
  final tracks = await crawl.stream
      .where((res) => res.fetch.tag == 'album')
      .asyncExpand((res) => Stream.fromIterable(_tracks(res)))
      .toList();

  log.ok(
    '${crawl.stats.fetched} pages, ${crawl.stats.failed} failed, '
    'in ${crawl.stats.elapsed.inMilliseconds}ms',
  );

  for (final track in tracks) {
    log.info('${track.artist} — ${track.album} — ${track.title}');
  }
}

/// The whole router: reply in, next requests out. A pure function, so it is
/// testable with a `Reply.text` fixture and no crawl at all.
Iterable<Fetch> _next(Reply res) => switch (res.fetch.tag) {
  // The index: queue every artist, tagged so the next stage picks them up.
  null =>
    res
        .parse(format.html)
        .$('.artist a')
        .elements
        .transform(
          .map(
            (link) => res.follow(
              link.attributes['href'] ?? '',
              tag: 'artist',
              meta: [artist(util.text.clean(link.text))],
              // Artists are cheap and unlock everything else, so serve them first.
              priority: 10,
            ),
          ),
        ),
  // An artist: queue their albums, passing the name down.
  'artist' =>
    res
        .parse(format.html)
        .$('.album a')
        .elements
        .transform(
          .map(
            (link) => res.follow(
              link.attributes['href'] ?? '',
              tag: 'album',
              meta: [
                if (res.fetch.meta.read(artist) ??
                        res.parse(format.html).pick(Field.text('h1'))
                    case final name?)
                  artist(name),
                album(util.text.clean(link.text)),
              ],
            ),
          ),
        ),
  // An album is a leaf: nothing further to fetch.
  _ => const <Fetch>[],
};

/// One track per row of an album page.
Iterable<Track> _tracks(Reply res) {
  final by = res.fetch.meta.read(artist) ?? '';
  final on =
      res.fetch.meta.read(album) ??
      res.parse(format.html).pick(Field.text('h1')) ??
      '';
  return res
      .parse(format.html)
      .$('.track')
      .elements
      .transform(
        .map(
          (row) => (
            artist: by,
            album: on,
            title: util.text.clean(row.query.$('.title').text),
          ),
        ),
      )
      .transform(.where((track) => track.title.isNotEmpty));
}

/// The fixture transport: a closure over a map, which is what `MapDownloader`
/// was an exported class for.
Future<Reply> _fixture(Fetch fetch) async {
  final body = _fixtures['${fetch.url}'];
  return Reply.text(body ?? '', fetch: fetch, status: body == null ? 404 : 200);
}

const _fixtures = <String, String>{
  'https://music.test/artists': '''
    <div class="artist"><a href="/artists/nujabes">Nujabes</a></div>
    <div class="artist"><a href="/artists/dj-okawari">DJ Okawari</a></div>
  ''',
  'https://music.test/artists/nujabes': '''
    <h1>Nujabes</h1>
    <div class="album"><a href="/albums/modal-soul">Modal Soul</a></div>
  ''',
  'https://music.test/artists/dj-okawari': '''
    <h1>DJ Okawari</h1>
    <div class="album"><a href="/albums/diorama">Diorama</a></div>
  ''',
  'https://music.test/albums/modal-soul': '''
    <h1>Modal Soul</h1>
    <div class="track"><span class="title">Feather</span></div>
    <div class="track"><span class="title">Luv (sic) Part 3</span></div>
  ''',
  'https://music.test/albums/diorama': '''
    <h1>Diorama</h1>
    <div class="track"><span class="title">Flower Dance</span></div>
  ''',
};
