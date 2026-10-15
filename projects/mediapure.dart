// Mirrors the Pure Media albums: the catalog (cached in result.json) and each album's
// thumbnail into imgs/. A volume number keeps that volume only.
//
//   dart run projects/mediapure.dart [volume]
//
// The shop holds more than 300 albums over a few listing pages, so the catalog walks
// every listing page until one adds nothing new, then fills the gaps by searching
// the missing volume numbers. Reruns read result.json, skip thumbnails on disk and
// resume cut-off ones.
library;

import 'dart:math';

import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/pool.dart';
import 'package:dart_toolkit/scrape.dart';

const mall = 'https://puremedia.kr/mall/';

final volumeInTitle = RegExp(r'VOL\s?(\d+)');
final artistAndName = RegExp(r'^\s?\[([^\]]*)\]\s?(.*)$');
final hangul = RegExp('[가-힣]+');

/// The shop: in Korean, retried, a quarter second between requests.
final shop = Http.client(
  base: mall,
  headers: {'accept-language': 'ko-KR'},
  retries: 3,
  rate: Rate(1, 250.milliseconds),
);

typedef Album = Map<String, Object?>;

final volume = Arg<int?>('volume', 'Keep this volume only.');

Future<void> main(List<String> args) =>
    Command('mediapure', 'Mirror the Pure Media albums into mediapure/.', params: [volume], handler: mirror).run(args);

Future<void> mirror(Context c) async {
  final out = Fs.dir('mediapure');
  final albums = await catalog(out.file('result.json'));
  final thumbnails = [
    for (final album in albums)
      if (c(volume) == null || album['volume'] == c(volume))
        if (album['image'] case final String image when image.isNotEmpty)
          (image, out.dir('imgs').dir(folder(album)).file('thumbnail.jpg')),
  ];
  final bar = Console.bar(thumbnails.length, label: 'Thumbnails');
  final cdn = Http.client(retries: 3, resume: true);
  await Pool.map(thumbnails, (t) => cdn.get(t.$1) > t.$2, onDone: bar.tick);
}

sealed class Job {}

final class Listing extends Job {
  Listing(this.page);
  final int page;
}

final class Search extends Job {
  Search(this.volume);
  final int volume;
}

final class Detail extends Job {
  Detail(this.url);
  final String url;
}

/// Every listing page until one adds nothing new, every album found, then a search for each
/// volume number the listings missed.
Future<List<Album>> catalog(File cache) async {
  final saved = await cache.json(or: Json.of(const []));
  if (saved.isNotEmpty) return [for (final album in saved) album.asMap<Object?>()];
  final known = <String>{};
  Future<void> visit(Visit<Job, Album> v) async {
    switch (v.item) {
      case Listing(:final page):
        final fresh = [
          for (final l in await links('m_mall_list.php', {'ps_page': page}))
            if (v.add(Detail(l))) l,
        ];
        if (fresh.isNotEmpty) v.add(Listing(page + 1));
      case Search(:final volume):
        for (final l in await links('m_search.php', {'ps_search': volume})) {
          if (!known.contains(l)) v.add(Detail(l));
        }
      case Detail(:final url):
        v.emit(readAlbum(await shop.get(url).html(), url));
    }
  }

  Scrape<Job, Album> crawl(String label) => Scrape(
    key: (j) => switch (j) {
      Listing(:final page) => 'page $page',
      Search(:final volume) => 'volume $volume',
      Detail(:final url) => url,
    },
    onProgress: Console.bar(null, label: label).update,
  );
  final albums = await crawl('Albums').run([Listing(1)], onItem: visit).toList();
  known.addAll([for (final a in albums) a['url'] as String]);
  albums.addAll(
    await crawl('Missing volumes').run([for (final v in missingVolumes(albums)) Search(v)], onItem: visit).toList(),
  );
  albums.sort((a, b) => ((a['volume'] as int?) ?? 1 << 20).compareTo((b['volume'] as int?) ?? 1 << 20));
  await cache.write(Json.encode(albums, pretty: true));
  return albums;
}

/// The album links on one shop page.
Future<List<String>> links(String path, Map<String, Object?> query) async => [
  for (final href in await shop.get(path, query: query).html().$('a[href*="m_mall_detail"]').attrs('href'))
    if (Uri.tryParse(href)?.queryParameters['ps_goid'] case final id?) '${mall}m_mall_detail.php?ps_goid=$id',
];

Album readAlbum(Elements page, String url) {
  String? meta(String property) => page.$('meta[property="$property"]').attr('content')?.trim();
  final title = meta('og:title') ?? page.$('div.goodsName').text();
  final named = artistAndName.firstMatch(title);
  return {
    'id': int.parse(Uri.parse(url).queryParameters['ps_goid']!),
    'volume': int.tryParse(volumeInTitle.firstMatch(title)?[1] ?? ''),
    'artist': named?[1]?.trim(),
    'name': hangul.firstMatch(named?[2] ?? title)?[0],
    'title': title,
    'image': meta('og:image'),
    'url': url,
  };
}

List<int> missingVolumes(List<Album> albums) {
  final volumes = {for (final album in albums) ?album['volume'] as int?};
  final last = volumes.fold(0, max);
  return [
    for (var v = 1; v <= last; v++)
      if (!volumes.contains(v)) v,
  ];
}

String folder(Album album) {
  final names = [?album['artist'] as String?, ?album['name'] as String?].join(' ');
  final prefix = switch (album['volume']) {
    final int v => 'VOL ${'$v'.padLeft(3, '0')}',
    _ => 'NO_VOL',
  };
  return '$prefix - ${Fs.sanitize(names.isEmpty ? '${album['title']}' : names)} (${album['id']})';
}
