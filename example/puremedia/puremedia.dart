import 'dart:math';

import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/chrome.dart';
import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/image.dart';
import 'package:dart_toolkit/scrape.dart';

final volumeOption = Option.of<int>('volume', 'Only this volume', short: 'v');
const finishedAlbums = Key<List<String>>('albums', or: []);

const shop = 'https://puremedia.kr/mall/';
const misskon = 'https://misskon.com/tag/pure-media/';
const knownPasswords = ['mrcong.com', 'misskon.com'];

final volumeInTitle = RegExp(r'VOL\s?(\d+)');
final volumeInPost = RegExp(r'vol\.?\s?(\d+)', caseSensitive: false);
final artistAndName = RegExp(r'^\s?\[([^\]]*)\]\s?(.*)$');
final hangul = RegExp('[가-힣]+');
final photoCount = RegExp(r'(\d+) photos');
final rarPart = RegExp(r'\.part(\d+)\.rar$');

typedef Post = ({String title, Uri url});
typedef Part = ({Uri file, Uri page});

Future<void> main(List<String> args) => Cli(
  'Mirrors the Pure Media albums.',
  values: [volumeOption],
  handler: (ctx) => Http.scope(retry: Retry(3), () async {
    final here = Path.here.parent;
    final images = here / 'imgs';
    final volume = ctx(volumeOption);
    bool wanted(Object? albumVolume) => volume == null || albumVolume == volume;

    final catalog = [
      for (final album in await loadCatalog(here / 'result.json'))
        if (wanted(album['volume'])) album,
    ];
    await downloadThumbnails(catalog, images);

    final posts = await listPosts();
    final albums = [
      for (final album in albumsFor(posts, catalog, images))
        if (wanted(album.volume)) album,
    ];

    final chrome = await Chrome.launch(block: Resource.heavy);
    ctx.defer(chrome.close);
    for (final (i, album) in albums.indexed) {
      final finished = await ctx.store.read(finishedAlbums);
      if (finished.contains(album.name)) continue;
      await mirror(album, chrome, '[${i + 1}/${albums.length}] ${album.name}');
      await ctx.store.update(finishedAlbums, (names) => [...names, album.name]);
    }
  }),
).run(args);

Future<void> mirror(Album album, Chrome chrome, String title) async {
  if (!await album.isExtracted()) {
    final (:parts, :password) = await album.findParts(chrome).show('$title · finding parts');
    final files = await parts
        .parallelize((part) => downloadPart(part, album.folder), concurrency: 3)
        .show('$title · downloading');
    for (final file in files.where(isFirstVolume)) {
      await extract(file, album.folder, password).show('$title · extracting');
    }
  }
  await album.folder
      .files(only: '*.{jpg,jpeg,png}')
      .parallelize((photo) => photo.compress(original: Original.delete))
      .show('$title · compressing');
}

Task<Path> downloadPart(Part part, Path folder) =>
    part.file.download(into: folder, accept: 'application/', headers: {'referer': '${part.page}'});

bool isFirstVolume(Path archive) => (rarPart.firstMatch(archive.name)?[1] ?? '1') == '1';

Task<Path> extract(Path archive, Path folder, String? postPassword) => Task.run(archive.name, (_) async {
  for (final password in {?postPassword, ...knownPasswords}) {
    try {
      return await archive.unarchive(
        into: folder,
        password: Secret(password),
        flatten: true,
        original: Original.delete,
      );
    } on PasswordException {
      continue;
    }
  }
  throw PasswordException('Invalid password for $archive: none of the known ones opens it');
});

Future<void> downloadThumbnails(List<Row> catalog, Path images) => [
  for (final album in catalog)
    if (album['image'] case final String image when image.isNotEmpty)
      (url: image.url, to: images / albumFolder(album) / 'thumbnail.jpg'),
].parallelize((thumbnail) => thumbnail.url.download(to: thumbnail.to), concurrency: 8).show('Thumbnails');

final class Album {
  final int volume;
  final Post post;
  final Path folder;

  const Album(this.volume, this.post, this.folder);

  String get name => folder.name;

  Future<bool> isExtracted() async =>
      await folder.exists() &&
      await folder.files(only: '*.{rar,zip,7z}').isEmpty &&
      await folder.files(only: '*.{jpg,jpeg,png,webp}').any((photo) => photo.name != 'thumbnail.jpg');

  Task<({List<Part> parts, String? password})> findParts(Chrome chrome) => Task.run(name, (work) async {
    final page = await post.url.get().html;
    final links = [
      for (final button in page.$('a.shortc-button'))
        if (button.text.contains('MediaFire')) button.link,
    ];
    if (links.isEmpty) throw MissingException('MediaFire link', where: '${post.url}');

    final parts = <Part>[];
    for (final link in links) {
      work.amount(parts.length, total: links.length, unit: Unit.items);
      final mediafire = link.host.startsWith('ouo.') ? await skipOuo(chrome, link) : link;
      final file = (await mediafire.get().html).$('#downloadButton').link;
      parts.add((file: file, page: mediafire));
    }
    return (parts: parts, password: passwordOn(page));
  });
}

String? passwordOn(Html page) {
  final labels = page.$('div.box.info strong').where((label) => label.text.toLowerCase().contains('password'));
  final field = labels.firstOrNull?.next;
  if (field == null) return null;
  return field.attr('value', or: field.text).trim();
}

Task<Uri> skipOuo(Chrome chrome, Uri link) => Task.run('$link', (work) async {
  final page = await chrome.open(link, render: const Render(wait: Wait.dom));
  work.defer(page.close);
  for (var step = 0; step < 3 && page.url.host.startsWith('ouo.'); step++) {
    await page.wait('#btn-main:not(.disabled)');
    await page.submit('#btn-main');
  }
  if (page.url.host.startsWith('ouo.')) throw MissingException('way past ouo.io', where: '${page.url}');
  return page.url;
});

Future<List<Post>> listPosts() async {
  final pages = await misskon.url
      .crawl<Post>(
        onResponse: (page) {
          for (final link in page.html.$('h2.post-box-title a')) {
            page.emit((title: link.text.trim(), url: link.link));
          }
          page.html.$('.pagination a').links.forEach(page.follow);
        },
      )
      .show('Listing MissKon');
  return pages.expand((posts) => posts).toList();
}

List<Album> albumsFor(List<Post> posts, List<Row> catalog, Path images) {
  final catalogByVolume = {
    for (final album in catalog)
      if (album['volume'] case final int volume) volume: album,
  };
  final postsByVolume = <int, Set<Post>>{};
  for (final post in posts) {
    if (volumeInPost.firstMatch(post.title)?[1] case final volume?) {
      postsByVolume.putIfAbsent(int.parse(volume), () => {}).add(post);
    }
  }

  final volumes = postsByVolume.keys.toList()..sort();
  return [
    for (final volume in volumes)
      for (final post in postsByVolume[volume]!)
        Album(
          volume,
          post,
          images /
              postFolder(catalogByVolume[volume], volume, post.title, severalPosts: postsByVolume[volume]!.length > 1),
        ),
  ];
}

String postFolder(Row? album, int volume, String title, {required bool severalPosts}) {
  final folder = album != null ? albumFolder(album) : '${volumeLabel(volume)} - ${title.filename}';
  if (!severalPosts) return folder;
  final edition = title.contains('AI Enhanced') ? 'AI Enhanced' : '${photoCount.firstMatch(title)?[1]} photos';
  return '$folder [$edition]';
}

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
