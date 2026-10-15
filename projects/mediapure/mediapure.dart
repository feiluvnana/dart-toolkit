// Mirrors the Pure Media album catalog next to this script: result.json with
// every album, and each album's thumbnail under imgs/.
//
//   dart run projects/mediapure/mediapure.dart [volume]
//
// The catalog is cached in result.json; delete it to crawl the shop again.
// Pass a volume number to download only that volume's thumbnail.
library;

import 'dart:math';

import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/pool.dart';

const mall = 'https://puremedia.kr/mall/';

final volumeInTitle = RegExp(r'VOL\s?(\d+)');
final artistAndName = RegExp(r'^\s?\[([^\]]*)\]\s?(.*)$');
final hangul = RegExp('[가-힣]+');

final shop = Http.client(
  base: mall,
  headers: {'accept-language': 'ko-KR'},
  retries: 3,
  rate: Rate(1, 250.milliseconds),
);
final cdn = Http.client(retries: 3, resume: true);

typedef Album = Map<String, Object?>;

final volumeArg = Arg<int?>('volume', 'Keep this volume only.');

Future<void> main(List<String> args) => Command(
  'mediapure',
  'Mirror the Pure Media albums next to this script.',
  params: [volumeArg],
  handler: mirror,
).run(args);

Future<void> mirror(Context c) async {
  final out = Fs.scriptDir();
  final albums = await catalog(out.file('result.json'));
  final only = c(volumeArg);

  final thumbnails = <(String, File)>[];
  for (final album in albums) {
    if (only != null && album['volume'] != only) continue;
    final image = album['image'] as String?;
    if (image == null || image.isEmpty) continue;
    thumbnails.add((image, out.dir('imgs').dir(folderName(album)).file('thumbnail.jpg')));
  }

  if (thumbnails.isEmpty) return Console.log(only == null ? 'no album has a thumbnail' : 'no album with volume $only');
  final bar = Console.bar(thumbnails.length, label: 'thumbnails done');
  await Pool.map(thumbnails, (t) async {
    final (url, to) = t;
    if (await to.exists()) return;
    await (cdn.get(url) | Console.bar(null, label: '  ${to.parent().name()}', keep: false) > to);
  }, onDone: bar.tick);
  Console.log(
    'done: ${thumbnails.length == 1 ? '1 thumbnail' : '${thumbnails.length} thumbnails'} in ${out.dir('imgs').path()}',
  );
}

Future<List<Album>> catalog(File cache) async {
  final saved = await cache.json(or: Json.of(const []));
  if (saved.isNotEmpty) {
    Console.log('using the saved catalog in ${cache.path()} (delete it to crawl the shop again)');
    return [for (final album in saved) album.asMap<Object?>()];
  }

  // The listing doesn't say how many pages it has, so stop at the first page
  // that shows nothing new.
  final urls = <String>{};
  final pages = Console.bar(null, label: 'reading the shop listing');
  for (var page = 1; ; page++) {
    final before = urls.length;
    urls.addAll(await albumLinks('m_mall_list.php', {'ps_page': page}));
    pages.tick();
    if (urls.length == before) break;
  }
  await pages.close();
  final albums = await fetchAlbums(urls, 'reading album pages');

  // A few albums never appear in the listing, but the search finds them by
  // volume number.
  final missing = missingVolumes(albums);
  final bar = Console.bar(missing.length, label: 'searching for ${missing.length} missing volumes');
  final extra = <String>{};
  for (final volume in missing) {
    for (final url in await albumLinks('m_search.php', {'ps_search': volume})) {
      if (!urls.contains(url)) extra.add(url);
    }
    bar.tick();
  }
  albums.addAll(await fetchAlbums(extra, 'reading the albums the search found'));

  albums.sort((a, b) => volumeOf(a).compareTo(volumeOf(b)));
  await cache.write(Json.encode(albums, pretty: true));
  Console.log('${albums.length} albums (${extra.length} found by search) saved to ${cache.path()}');
  return albums;
}

Future<List<Album>> fetchAlbums(Set<String> urls, String label) {
  final bar = Console.bar(urls.length, label: label);
  return Pool.map(urls, (url) async {
    final album = readAlbum(await shop.get(url).html(), url);
    Console.log('  ${folderName(album)}');
    return album;
  }, onDone: bar.tick);
}

Future<List<String>> albumLinks(String path, Map<String, Object?> query) async {
  final page = await shop.get(path, query: query).html();
  final links = <String>[];
  for (final href in page.$('a[href*="m_mall_detail"]').attrs('href')) {
    final id = Uri.tryParse(href)?.queryParameters['ps_goid'];
    if (id != null) links.add('${mall}m_mall_detail.php?ps_goid=$id');
  }
  return links;
}

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

// Albums without a volume number sort last.
int volumeOf(Album album) => album['volume'] as int? ?? 1000000;

List<int> missingVolumes(List<Album> albums) {
  final have = {
    for (final album in albums)
      if (album['volume'] case final int v) v,
  };
  if (have.isEmpty) return [];
  final last = have.reduce(max);
  return [
    for (var v = 1; v <= last; v++)
      if (!have.contains(v)) v,
  ];
}

String folderName(Album album) {
  final artist = album['artist'] as String?;
  final name = album['name'] as String?;
  var label = [?artist, ?name].join(' ');
  if (label.isEmpty) label = '${album['title']}';

  final volume = album['volume'] as int?;
  final prefix = volume == null ? 'NO_VOL' : 'VOL ${'$volume'.padLeft(3, '0')}';
  return '$prefix - ${Fs.sanitize(label)} (${album['id']})';
}
