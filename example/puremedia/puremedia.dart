// Mirrors the Pure Media albums: the catalog (cached in result.json) and each album's
// thumbnail into imgs/, next to this script. `--volume N` (or `-v N`) keeps one volume.
//
//   dart run example/puremedia/puremedia.dart [--volume N]
library;

import 'dart:async';
import 'dart:io' as io;
import 'dart:math';

import 'package:dart_toolkit/async.dart';
import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/path.dart';

const shop = 'https://puremedia.kr/mall/';
const korean = {'accept-language': 'ko-KR'};

final volumeInTitle = RegExp(r'VOL\s?(\d+)');
final artistAndName = RegExp(r'^\s?\[([^\]]*)\]\s?(.*)$');
final hangul = RegExp('[가-힣]+');

final here = File(io.Platform.script.toFilePath()).parent;

typedef Album = Map<String, Object?>;

Future<void> main(List<String> args) async {
  final volume = volumeArgument(args);
  final catalog = [
    for (final album in await loadCatalog(here.file('result.json')))
      if (volume == null || album['volume'] == volume) album,
  ];
  await downloadThumbnails(catalog, here.dir('imgs'));
}

/// `--volume N` / `-v N`, or null; anything else is a usage error (exit 64, rule 30).
int? volumeArgument(List<String> args) {
  if (args.isEmpty) return null;
  final at = args.indexWhere((a) => a == '-v' || a == '--volume');
  final value = at != -1 && at + 1 < args.length ? int.tryParse(args[at + 1]) : null;
  if (value == null || args.length != 2) {
    Cli.print('usage: dart run example/puremedia/puremedia.dart [--volume N]');
    io.exit(64);
  }
  return value;
}

Future<List<Album>> loadCatalog(File file) async {
  if (await file.exists()) {
    final saved = (await file.json()).value! as List<Object?>;
    return [for (final album in saved) Map<String, Object?>.from(album! as Map)];
  }
  final albums = await scrapeCatalog();
  albums.sort((a, b) => sortKey(a).compareTo(sortKey(b)));
  await Json(albums).save(file, pretty: true);
  return albums;
}

int sortKey(Album album) => album['volume'] as int? ?? 1000000;

/// One polite request: a quarter second apart, in Korean, retried.
Future<Doc> page(String url) async {
  await Future<void>.delayed(const Duration(milliseconds: 250));
  return Http.get(url, headers: korean, retry: 3).html();
}

Future<List<Album>> scrapeCatalog() async {
  final listed = await albumLinks([for (var p = 1; p <= 3; p++) '${shop}m_mall_list.php?ps_page=$p']);
  final albums = await readAlbums(listed);
  final searches = [for (final v in missingVolumes(albums)) '${shop}m_search.php?ps_search=$v'];
  final found = await albumLinks(searches);
  return [...albums, ...await readAlbums(found.difference(listed))];
}

Future<Set<String>> albumLinks(List<String> pages) async {
  final bar = Cli.bar(pages.length, label: 'Listing puremedia.kr');
  final links = <String>{};
  for (final url in pages) {
    for (final a in (await page(url)).all('a[href*="m_mall_detail"]')) {
      if (Uri.parse(link(url, a.attr('href')!)).queryParameters['ps_goid'] case final id?) {
        links.add('${shop}m_mall_detail.php?ps_goid=$id');
      }
    }
    bar.tick();
  }
  bar.close();
  return links;
}

Future<List<Album>> readAlbums(Set<String> links) async {
  final bar = Cli.bar(links.length, label: 'puremedia.kr');
  final albums = <Album>[];
  for (final url in links) {
    albums.add(readAlbum(await page(url), Uri.parse(url)));
    bar.tick();
  }
  bar.close();
  return albums;
}

Album readAlbum(Doc page, Uri url) {
  final title = metaOf(page, 'og:title') ?? page.find('div.goodsName')?.text.trim() ?? '';
  final named = artistAndName.firstMatch(title);
  return {
    'id': int.parse(url.queryParameters['ps_goid']!),
    'volume': int.tryParse(volumeInTitle.firstMatch(title)?[1] ?? ''),
    'artist': named?[1]?.trim(),
    'name': hangul.firstMatch(named?[2] ?? title)?[0],
    'title': title,
    'image': metaOf(page, 'og:image'),
    'url': '$url',
  };
}

String? metaOf(Doc page, String property) => page.find('meta[property="$property"]')?.attr('content')?.trim();

List<int> missingVolumes(List<Album> albums) {
  final volumes = {
    for (final album in albums)
      if (album['volume'] case final int volume) volume,
  };
  final last = volumes.fold(0, max);
  return [
    for (var v = 1; v <= last; v++)
      if (!volumes.contains(v)) v,
  ];
}

Future<void> downloadThumbnails(List<Album> catalog, Dir images) async {
  final jobs = [
    for (final album in catalog)
      if (album['image'] case final String image when image.isNotEmpty)
        (url: image, to: images.dir(albumFolder(album)).file('thumbnail.jpg').path),
  ];
  final bar = Cli.bar(jobs.length, label: 'Thumbnails');
  final pool = Pool(4);
  await Future.wait([for (final job in jobs) pool.run(bind(save, job)).whenComplete(bar.tick)]);
  await pool.close();
  bar.close();
}

/// One thumbnail, skipped when it is already there. Runs on a Pool worker.
Future<void> save(({String url, String to}) job) async {
  final to = File(job.to);
  if (await to.exists()) return;
  await to.parent.make();
  await Http.get(job.url, retry: 3).pipe(to);
}

String albumFolder(Album album) {
  final volume = album['volume'];
  final names = {?album['artist'], ?album['name']}.join(' ');
  final label = names.isEmpty ? '${album['title']}' : names;
  final prefix = volume is int ? 'VOL ${'$volume'.padLeft(3, '0')}' : 'NO_VOL';
  return '$prefix - ${safeName(label)} (${album['id']})';
}

String link(String base, String href) => Uri.parse(base).resolve(href).toString();

String safeName(String s) => s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').replaceAll(RegExp(r'\s+'), ' ').trim();

/// [f] applied to [x], as a job for a Pool worker. Built here, at the top level, so the
/// closure holds only [f] and [x], never the caller's other locals (rule 52).
FutureOr<R> Function() bind<T, R>(FutureOr<R> Function(T) f, T x) =>
    () => f(x);
