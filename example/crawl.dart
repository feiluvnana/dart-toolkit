// Walk a site in stages.
//
//   dart run example/crawl.dart
//
// A listing page queues detail pages, each detail page queues its own, and
// every stage has its own handler. `route` dispatches on the URL, `tag` on
// whatever queued the request, and `meta` carries context between the two so
// a handler never re-parses what its parent already knew.
//
// The fixture downloader stands in for the network; drop the `.downloader(...)`
// line and the same crawl runs against the real site.

import 'package:dart_toolkit/dart_toolkit.dart';

typedef Track = ({String artist, String album, String title});

// Typed keys, declared once and checked at both ends: `artist('Nujabes')` will
// not compile with a number in it, and `res.meta.read(artist)` hands back a
// String? without a cast.
const artist = Slot<String>('artist');
const album = Slot<String>('album');

void main() async {
  final log = system.console.logger;

  final tracks = await net
      .crawl<Track>('https://music.test/artists'.url)
      .downloader(MapDownloader<Track>(_fixtures))
      // Politeness and scope. Without these a crawl wanders off the site it
      // started on; `perhost` paces each host separately once seeds span more
      // than one.
      .concurrent(4)
      .delay(20.ms)
      .samehost()
      .depth(3)
      .limit(500)
      .allow(RegExp(r'music\.test/(artists|albums)'))
      .deny(RegExp(r'\?(sort|filter)='))
      .headers({'User-Agent': 'ExampleBot/1.0 (+https://example.com/bot)'})
      // A crawl that has to survive the real world adds four more:
      //   .robots(true, 'ExampleBot/1.0')  obey robots.txt, Crawl-delay included
      //   .cache('.cache')                 reuse pages that have not changed
      //   .resume('crawl.state')           carry on where an interrupt stopped
      //   .accept(['text/html'])           never hand a PDF to the HTML parser
      // The stages.
      .route(RegExp(r'/artists$'), _index)
      .tag('artist', _artist)
      .tag('album', _album)
      // Without an error handler a crawl swallows failures so one bad page
      // cannot end the run.
      .on
      .error((f) => log.warn('${f.fetch?.url ?? 'crawl'}: ${f.error}'))
      .on
      .done(
        (s) => log.ok('${s.completed} pages in ${s.elapsed.inMilliseconds}ms'),
      )
      .collect();

  // `collect` returns a List<Track>. `stream` yields them as they arrive and
  // `save(path)` writes each to disk, so a long crawl never holds its results
  // in memory.
  for (final track in tracks.collect(.list())) {
    log.info('${track.artist} — ${track.album} — ${track.title}');
  }
}

/// Stage 1, the index: queue every artist, tagged so stage 2 picks them up.
void _index(Page<Track> res) {
  for (final link
      in res.parse(format.html).find('.artist a').elements.collect(.list())) {
    res.follow(
      link.attributes['href'] ?? '',
      tag: 'artist',
      meta: [artist(util.text.clean(link.text))],
      // Artists are cheap and unlock everything else, so serve them first.
      priority: 10,
    );
  }
}

/// Stage 2, an artist: queue their albums, passing the name down.
void _artist(Page<Track> res) {
  final name =
      res.meta.read(artist) ?? res.parse(format.html).pick(Field.text('h1'));
  for (final link
      in res.parse(format.html).find('.album a').elements.collect(.list())) {
    res.follow(
      link.attributes['href'] ?? '',
      tag: 'album',
      meta: [if (name != null) artist(name), album(util.text.clean(link.text))],
    );
  }
}

/// Stage 3, an album: emit one item per track.
void _album(Page<Track> res) {
  final by = res.meta.read(artist) ?? '';
  final on =
      res.meta.read(album) ??
      res.parse(format.html).pick(Field.text('h1')) ??
      '';

  for (final row
      in res.parse(format.html).find('.track').elements.collect(.list())) {
    final title = util.text.clean(row.query.find('.title').text);
    if (title.isNotEmpty) res.emit((artist: by, album: on, title: title));
  }
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
