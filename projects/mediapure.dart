// Mirrors the Pure Media albums: the catalog (cached in result.json) and each album's
// thumbnail into imgs/. A volume number keeps that volume only.
//
//   dart run projects/mediapure.dart [volume]
//
// The shop holds more than 300 albums over a few listing pages, so the catalog walks
// every listing page until one adds nothing new, then fills the gaps by searching
// the missing volume numbers. Reruns read result.json and skip thumbnails on disk.
library;

import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/pool.dart';

const shop = 'https://puremedia.kr/mall/';

final volumeInTitle = RegExp(r'VOL\s?(\d+)');
final artistAndName = RegExp(r'^\s?\[([^\]]*)\]\s?(.*)$');
final hangul = RegExp('[가-힣]+');

typedef Album = Map<String, Object?>;

Future<void> main(List<String> args) async {
  final volume = args.isEmpty ? null : int.parse(args.last);
  final out = Fs.dir('mediapure');
  final albums = await catalog(out.file('result.json'));
  final thumbnails = <(String, File)>[];
  for (final album in albums) {
    if (volume != null && album['volume'] != volume) continue;
    final image = album['image'];
    if (image is String && image.isNotEmpty) {
      thumbnails.add((image, out.dir('imgs').dir(folder(album)).file('thumbnail.jpg')));
    }
  }
  final bar = Console.bar(thumbnails.length, label: 'Thumbnails');
  await Pool.map(thumbnails, save, onResult: (_) => bar.tick());
}

/// One thumbnail, skipped when it is already there.
Future<void> save((String, File) thumbnail) async {
  final (url, to) = thumbnail;
  if (!await to.exists()) await (Http.get(url, retries: 3) > to);
}

Future<List<Album>> catalog(File cache) async {
  if (await cache.exists()) {
    return [for (final item in Json.parse(await cache.text())) item.asMap<Object?>()];
  }
  final listed = <String>{};
  for (var p = 1; ; p++) {
    final links = await albumLinks(['${shop}m_mall_list.php?ps_page=$p']);
    if (links.isEmpty) break;
    final before = listed.length;
    listed.addAll(links);
    if (listed.length == before) break;
    Console.log('listing page $p: ${listed.length} albums');
  }
  final albums = await readAlbums(listed);
  final found = await albumLinks([for (final v in missingVolumes(albums)) '${shop}m_search.php?ps_search=$v']);
  found.removeAll(listed);
  albums.addAll(await readAlbums(found));
  albums.sort((a, b) => ((a['volume'] as int?) ?? 1 << 20).compareTo((b['volume'] as int?) ?? 1 << 20));
  await cache.write(Json.encode(albums, pretty: true));
  return albums;
}

/// One polite request: a quarter second apart, in Korean, retried.
Future<Elements> page(String url) async {
  await Future<void>.delayed(const Duration(milliseconds: 250));
  return Http.get(url, headers: {'accept-language': 'ko-KR'}, retries: 3).html();
}

Future<Set<String>> albumLinks(List<String> pages) async {
  final out = <String>{};
  for (final url in pages) {
    for (final a in (await page(url)).$('a[href*="m_mall_detail"]')) {
      final href = a.attr('href');
      if (href == null) continue;
      final id = Uri.tryParse(href)?.queryParameters['ps_goid'];
      if (id != null) out.add('${shop}m_mall_detail.php?ps_goid=$id');
    }
  }
  return out;
}

Future<List<Album>> readAlbums(Set<String> links) async {
  final out = <Album>[];
  final bar = Console.bar(links.length, label: 'Albums');
  for (final url in links) {
    out.add(readAlbum(await page(url), url));
    bar.tick();
  }
  return out;
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

List<int> missingVolumes(List<Album> albums) {
  final volumes = {for (final album in albums) ?album['volume'] as int?};
  var last = 0;
  for (final v in volumes) {
    if (v > last) last = v;
  }
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
