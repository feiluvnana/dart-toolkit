import 'dart:math';

import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/collection.dart';
import 'package:dart_toolkit/image.dart';
import 'package:dart_toolkit/scrape.dart';

final volumeOption = Option.of<int>('volume', 'Only this volume', short: 'v');

const shop = 'https://puremedia.kr/mall/';

final volumeInTitle = RegExp(r'VOL\s?(\d+)');
final artistAndName = RegExp(r'^\s?\[([^\]]*)\]\s?(.*)$');
final hangul = RegExp('[가-힣]+');

Future<void> main(List<String> args) => Cli(
  'Mirrors the Pure Media albums.',
  values: [volumeOption],
  handler: (ctx) => Console.scope(
    theme: const ConsoleTheme(rows: 4, task: formatTask),
    () => Http.scope(retry: Retry(3), () async {
      final here = Path.here.parent;
      final images = here / 'imgs';
      final volume = ctx(volumeOption);
      bool wanted(Object? albumVolume) => volume == null || albumVolume == volume;

      final catalog = [
        for (final album in await loadCatalog(here / 'result.json'))
          if (wanted(album['volume'])) album,
      ];
      await downloadThumbnails(catalog, images);
    }),
  ),
).run(args);

final class _Thumbnail {
  final String label;
  final Uri url;
  final Path to;

  const _Thumbnail(this.label, this.url, this.to);

  @override
  String toString() => label;
}

String cleanTitle(String raw) {
  var s = raw.replaceAll(r'\', '/');
  if (s.endsWith('/thumbnail.jpg')) {
    s = s.substring(0, s.length - '/thumbnail.jpg'.length);
  }
  if (Uri.tryParse(s) case final uri? when uri.hasQuery) {
    if (uri.queryParameters['ps_goid'] case final id?) return 'Album #$id';
    if (uri.queryParameters['ps_page'] case final page?) return 'List page $page';
    if (uri.queryParameters['ps_search'] case final q?) return 'Search "$q"';
  }
  if (s.contains('/')) {
    s = s.split('/').last;
  }
  return s;
}

String pad(String text, int width) {
  final w = Style.width(text);
  if (w >= width) return Style.truncate(text, width);
  return text + ' ' * (width - w);
}

String formatTask(TaskView t) {
  final p = t.palette;
  const width = 32;
  final title = pad(cleanTitle(t.label), width);

  if (t.isOver) {
    final size = t.received > 0 ? ' (${t.received.humanBytes})' : '';
    final line = '${t.isRow ? '  ' : ''}${t.mark} $title$size';
    return t.isLive ? p.muted(line) : line;
  }

  final head = t.isRow ? '  ${p.accent(t.frame)} ' : '${p.accent(t.frame)} ';
  if (t.fraction != null) {
    final bar = p.accent(t.bar(16));
    final percent = '${t.percent}%'.padLeft(4);
    final metrics = t.metrics.isNotEmpty ? '  ${p.muted(t.metrics)}' : '';
    return '$head$title  $bar  $percent$metrics';
  }

  final info = t.metrics.isNotEmpty ? t.metrics : '(${t.elapsed.humanized})';
  return '$head$title  ${p.muted(info)}';
}

Future<void> downloadThumbnails(List<Row> catalog, Path images) => [
  for (final album in catalog)
    if (album['image'] case final String image when image.isNotEmpty)
      _Thumbnail(albumFolder(album), image.url, images / albumFolder(album) / 'thumbnail.jpg'),
].parallelize((thumbnail) => thumbnail.url.download(to: thumbnail.to), concurrency: 4).show('Thumbnails');

String albumFolder(Map<String, Object?> album) {
  final volume = album['volume'];
  final names = {?album['artist'], ?album['name']}.join(' ');
  final label = names.isEmpty ? '${album['title']}' : names;
  final prefix = volume is int ? volumeLabel(volume) : 'NO_VOL';
  return '$prefix - ${label.filename} (${album['id']})';
}

String volumeLabel(int volume) => 'VOL ${'$volume'.padLeft(3, '0')}';

Future<List<Row>> loadCatalog(Path file) async {
  if (await file.exists()) return (await Table.read(file)).rows;
  final albums = await Http.scope(headers: {'accept-language': 'ko-KR'}, delay: 250.ms, scrapeCatalog);
  albums.sort((a, b) => sortKey(a).compareTo(sortKey(b)));
  final table = Table.rows(albums);
  await table.save(file);
  return table.rows;
}

int sortKey(Map<String, Object?> album) => album['volume'] as int? ?? 1000000;

Future<List<Map<String, Object?>>> scrapeCatalog() async {
  final listed = await albumLinks([for (var page = 1; page <= 3; page++) '${shop}m_mall_list.php?ps_page=$page']);
  final albums = await readAlbums(listed);
  final searches = [for (final volume in missingVolumes(albums)) '${shop}m_search.php?ps_search=$volume'];
  final found = await albumLinks(searches);
  return [...albums, ...await readAlbums(found.difference(listed))];
}

Future<Set<String>> albumLinks(List<String> pages) async {
  final documents = await pages.parallelize((page) => page.url.get().html).show('Listing puremedia.kr');
  return {
    for (final document in documents)
      for (final link in document.$('a[href*="m_mall_detail"]'))
        if (link.link.queryParameters['ps_goid'] case final id?) '${shop}m_mall_detail.php?ps_goid=$id',
  };
}

Future<List<Map<String, Object?>>> readAlbums(Set<String> links) => links
    .parallelize((link) async => readAlbum(await link.url.get().html, link.url))
    .progress('puremedia.kr')
    .values
    .toList();

Map<String, Object?> readAlbum(Html page, Uri url) {
  final title = metaOf(page, 'og:title') ?? page.$('div.goodsName').text;
  final named = artistAndName.firstMatch(title);
  return {
    'id': int.parse(url.queryParameters['ps_goid']!),
    'volume': volumeInTitle.firstMatch(title)?[1]?.to<int>(),
    'artist': named?[1]?.trim(),
    'name': hangul.firstMatch(named?[2] ?? title)?[0],
    'title': title,
    'image': metaOf(page, 'og:image'),
    'url': '$url',
  };
}

String? metaOf(Html page, String property) => page.$('meta[property="$property"]').attrs('content').firstOrNull?.trim();

List<int> missingVolumes(List<Map<String, Object?>> albums) {
  final volumes = {
    for (final album in albums)
      if (album['volume'] case final int volume) volume,
  };
  final last = volumes.fold(0, max);
  return [
    for (var volume = 1; volume <= last; volume++)
      if (!volumes.contains(volume)) volume,
  ];
}
