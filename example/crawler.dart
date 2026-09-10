// A multi-stage crawl: a listing page queues detail pages, each detail page
// queues its own sub-pages, and every stage has its own handler.
//
//   dart run example/crawler.dart            # offline, against fixtures
//   dart run example/crawler.dart --live     # against the real site
//
// The shape is the point. `route` dispatches on the URL, `tag` dispatches on
// whatever queued the request, and `meta` carries context between the two so a
// handler never has to re-parse what its parent already knew.

import 'package:dart_toolkit/dart_toolkit.dart';

typedef Track = ({String artist, String album, String title, int number});

void main(List<String> args) async {
  final live = cli.flag(
    'live',
    desc: 'Fetch the real site instead of fixtures',
  );
  final out = cli.option(
    'out',
    alias: 'o',
    desc: 'JSON Lines output',
    def: 'tracks.jsonl',
  );
  cli.parse(args);

  final log = system.console.logger;

  final crawl = net
      .crawl<Track>('https://music.test/artists')
      // Politeness. `delay` alone paces the whole crawl; `perhost` paces each
      // host separately, which matters once seeds span several domains.
      .concurrent(4)
      .delay(500.ms)
      .perhost()
      // Scope. Without these a crawl wanders off the site it started on.
      .samehost()
      .depth(3)
      .limit(500)
      .allow(RegExp(r'music\.test/(artists|albums|tracks)'))
      .deny(RegExp(r'\?(sort|filter)='))
      // Obey robots.txt, identifying as this agent. Any Crawl-delay the site
      // declares becomes a floor on the pause between its pages.
      .robots(true, 'ExampleBot/1.0')
      .headers({'User-Agent': 'ExampleBot/1.0 (+https://example.com/bot)'})
      // Stages.
      .route(RegExp(r'/artists$'), _artists)
      .tag('artist', _artist)
      .tag('album', _album);

  if (!live()) crawl.downloader(MapDownloader<Track>(_fixtures));

  // Report progress and surface errors — without an error handler a crawl
  // swallows them so one bad page cannot end the run.
  crawl.on
    ..start(() => log.info('Starting...'))
    ..progress((res) => log.debug('${res.status} ${res.url}'))
    ..error((f) => log.warn('${f.fetch?.url ?? 'crawl'}: ${f.error}'))
    ..done((stats) {
      log.ok(
        '${stats.completed} pages, ${stats.emitted} tracks, '
        '${stats.failed} failed, ${stats.skipped} skipped by robots, '
        'in ${util.time.format(stats.elapsed)}',
      );
    });

  // `to` streams each item to disk as it arrives, so a long crawl never holds
  // its results in memory. `collect` returns a list; `stream` yields them.
  await crawl.save(out());

  log.ok('Wrote ${out()}');
}

// The context each stage passes to the next. Declared once, checked at both
// ends: `artist('Nick Drake')` will not compile with a number in it, and
// `res.meta.get(artist)` hands back a String? without a cast.
const artist = Slot<String>('artist');
const album = Slot<String>('album');

/// Stage 1 — the index. Queue every artist, tagged so stage 2 picks them up.
void _artists(Page<Track> res) {
  for (final link in res.$('.artist a')) {
    res.follow(
      link.attributes['href'] ?? '',
      tag: 'artist',
      meta: [artist(util.text.clean(link.text))],
      // Artists are cheap and unlock everything else, so serve them first.
      priority: 10,
    );
  }
}

/// Stage 2 — an artist. Queue their albums, passing the artist name down.
void _artist(Page<Track> res) {
  final name = res.meta.get(artist) ?? res.pick(Field.text('h1'));

  for (final link in res.$('.album a')) {
    res.follow(
      link.attributes['href'] ?? '',
      tag: 'album',
      meta: [if (name != null) artist(name), album(util.text.clean(link.text))],
    );
  }
}

/// Stage 3 — an album. Emit one item per track.
void _album(Page<Track> res) {
  final by = res.meta.get(artist) ?? '';
  final on = res.meta.get(album) ?? res.pick(Field.text('h1')) ?? '';

  var number = 0;
  for (final row in res.$('.track')) {
    number++;
    final title = util.text.clean(row.query.find('.title').text);
    if (title.isEmpty) continue;
    res.emit((artist: by, album: on, title: title, number: number));
  }

  // Stop early once a run has seen enough, from inside a handler.
  if (res.depth >= 3) res.stop('Reached the deepest stage');
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
