// Mirrors the Pure Media albums: the catalog (cached in result.json) and each album's
// thumbnail into imgs/, next to this script. A volume number keeps that volume only.
//
//   dart run example/puremedia/puremedia.dart [volume]
library;

import 'dart:math';

import 'package:dart_toolkit/async.dart';
import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/path.dart';

const shop = 'https://puremedia.kr/mall/';

final volumeInTitle = RegExp(r'VOL\s?(\d+)');
final artistAndName = RegExp(r'^\s?\[([^\]]*)\]\s?(.*)$');
final hangul = RegExp('[가-힣]+');

typedef Album = Map<String, Object?>;

Future<void> main(List<String> args) async {
  final volume = args.isEmpty ? null : int.parse(args.last);
  final thumbnails = [
    for (final album in await catalog(Dir.script.file('result.json')))
      if (volume == null || album['volume'] == volume)
        if (album['image'] case final String url when url.isNotEmpty)
          (url, Dir.script.dir('imgs').dir(folder(album)).file('thumbnail.jpg')),
  ];
  await Task.all(thumbnails, save, onProgress: Cli.bar(label: 'Thumbnails').set);
}

/// One thumbnail, skipped when it is already there.
Future<void> save((String, File) thumbnail) async {
  final (url, to) = thumbnail;
  if (!await to.exists()) await Http.get(url, retry: 3).pipe(to);
}

Future<List<Album>> catalog(File cache) async {
  if (await cache.exists()) return ((await cache.json()).value! as List).cast<Album>();
  final listed = await albumLinks([for (var p = 1; p <= 3; p++) '${shop}m_mall_list.php?ps_page=$p']);
  final albums = await readAlbums(listed);
  final found = await albumLinks([for (final v in missingVolumes(albums)) '${shop}m_search.php?ps_search=$v']);
  albums
    ..addAll(await readAlbums(found.difference(listed)))
    ..sort((a, b) => (a['volume'] as int? ?? 1 << 20).compareTo(b['volume'] as int? ?? 1 << 20));
  await Json(albums).save(cache, pretty: true);
  return albums;
}

/// One polite request: a quarter second apart, in Korean, retried.
Future<Doc> page(String url) async {
  await Future<void>.delayed(const Duration(milliseconds: 250));
  return Http.get(url, headers: {'accept-language': 'ko-KR'}, retry: 3).html();
}

Future<Set<String>> albumLinks(List<String> pages) async => {
  for (final url in Cli.each(pages, label: 'Listing'))
    for (final a in (await page(url)).all('a[href*="m_mall_detail"]'))
      if (Uri.parse(a.link()!).queryParameters['ps_goid'] case final id?) '${shop}m_mall_detail.php?ps_goid=$id',
};

Future<List<Album>> readAlbums(Set<String> links) async => [
  for (final url in Cli.each(links, label: 'Albums')) readAlbum(await page(url), url),
];

Album readAlbum(Doc page, String url) {
  String? meta(String property) => page.find('meta[property="$property"]')?.attr('content')?.trim();
  final title = meta('og:title') ?? page.find('div.goodsName')?.text.trim() ?? '';
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
  final names = {?album['artist'], ?album['name']}.join(' ');
  final prefix = switch (album['volume']) {
    final int v => 'VOL ${'$v'.padLeft(3, '0')}',
    _ => 'NO_VOL',
  };
  return '$prefix - ${File.safeName(names.isEmpty ? '${album['title']}' : names)} (${album['id']})';
}
