import 'dart:math';

import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/chrome.dart';
import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/image.dart';
import 'package:dart_toolkit/scrape.dart';

final _volume = Option.of<int>('volume', 'Only this volume', short: 'v');

/// The albums already mirrored, by folder: a rerun skips them.
const _finished = Key<List<String>>('albums', or: []);

/// The puremedia.kr catalog (`result.json`, scraped into it on the first run) and each album's
/// thumbnail, then every MissKon post of an album, one album at a time: its parts found through
/// Chrome, downloaded, extracted and its photos compressed, under `imgs/<album>/`. ^C stops
/// cleanly; a rerun picks up where it stopped; a stage that failed makes the run exit 1.
Future<void> main(List<String> args) => Cli(
  'Mirrors the Pure Media albums.',
  values: [_volume],
  handler: (ctx) => Http.scope(retry: Retry(3), () async {
    final here = Path.here.parent;
    final only = ctx(_volume);
    final catalog = [
      for (final album in await _catalog(here / 'result.json'))
        if (only == null || album['volume'] == only) album,
    ];
    await thumbnails(here / 'imgs', catalog);
    final albums = [
      for (final album in await misskon(here / 'imgs', catalog))
        if (only == null || album.volume == only) album,
    ];

    final chrome = await Chrome.launch(block: Resource.heavy);
    ctx.defer(chrome.close);
    for (final (i, album) in albums.indexed) {
      final tag = '[${i + 1}/${albums.length}] ${album.folder}';
      if ((await ctx.store.read(_finished)).contains(album.folder)) continue;
      if (!await album.extracted) {
        final (:parts, :password) = await album.parts(chrome).show('$tag · finding parts');
        final files = await parts
            .parallelize(
              (p) => p.file.download(into: album.dir, accept: 'application/', headers: {'referer': '${p.page}'}),
              concurrency: 3,
            )
            .show('$tag · downloading');
        for (final file in files.where(_isFirstVolume)) {
          await _extract(file, album.dir, password).show('$tag · extracting');
        }
      }
      await album.dir
          .files(only: '*.{jpg,jpeg,png}')
          .parallelize((p) => p.compress(original: Original.delete))
          .show('$tag · compressing');
      await ctx.store.update(_finished, (done) => [...done, album.folder]);
    }
  }),
).run(args);

/// Each album's `thumbnail.jpg` in its folder under [root], downloaded as one batch.
Future<void> thumbnails(Path root, List<Row> catalog) => [
  for (final album in catalog)
    if (album['image'] case final String image when image.isNotEmpty)
      (url: image.url, to: root / albumFolder(album) / 'thumbnail.jpg'),
].parallelize((t) => t.url.download(to: t.to), concurrency: 8).show('Thumbnails');

// ---- MissKon ---------------------------------------------------------------------------------

const _tag = 'https://misskon.com/tag/pure-media/';

/// What MissKon archives are locked with, tried after the password a post names.
const _passwords = ['mrcong.com', 'misskon.com'];

/// `Vol. 275`, `VOL 275`, `vol275`: the volume a post title names.
final _postVolume = RegExp(r'vol\.?\s?(\d+)', caseSensitive: false);

/// The part number of a RAR volume set: `x.part2.rar`.
final _part = RegExp(r'\.part(\d+)\.rar$');

typedef Post = ({String title, Uri url});

/// One file of a post, and the MediaFire page it was found on (its referer).
typedef Part = ({Uri file, Uri page});

/// One MissKon post of an album, and the folder it lands in.
final class Album {
  final int volume;
  final Post post;
  final Path dir;

  const Album(this.volume, this.post, this.dir);

  String get folder => dir.name;

  /// Whether its photos are out: no archive left, and a photo besides the thumbnail.
  Future<bool> get extracted async =>
      await dir.exists() &&
      await dir.files(only: '*.{rar,zip,7z}').isEmpty &&
      await dir.files(only: '*.{jpg,jpeg,png,webp}').any((f) => f.name != 'thumbnail.jpg');

  /// The post's files on MediaFire, each ouo.io link passed in Chrome, and the password it
  /// names.
  Task<({List<Part> parts, String? password})> parts(Chrome chrome) => Task.run(folder, (work) async {
    final doc = await post.url.get().html;
    // `Password unrar:` or `Unzip password:`, then the value in a <span> or an <input>.
    final field = doc
        .$('div.box.info strong')
        .where((s) => s.text.toLowerCase().contains('password'))
        .firstOrNull
        ?.next;
    final links = [
      for (final a in doc.$('a.shortc-button'))
        if (a.text.contains('MediaFire')) a.link,
    ];
    if (links.isEmpty) throw MissingException('MediaFire link', where: '${post.url}');
    final parts = <Part>[];
    for (final link in links) {
      work.amount(parts.length, total: links.length, unit: Unit.items);
      final page = link.host.startsWith('ouo.') ? await _ouo(chrome, link) : link;
      // Into the folder: MediaFire names the file (`Content-Disposition`).
      parts.add((file: (await page.get().html).$('#downloadButton').first.link, page: page));
    }
    return (parts: parts, password: field?.attr('value', or: field.text).trim());
  });
}

/// Every post under the tag, each in its catalog album's folder under [root]; two posts of one
/// volume are told apart by edition.
Future<List<Album>> misskon(Path root, List<Row> catalog) async {
  final official = {
    for (final album in catalog)
      if (album['volume'] case final int v) v: album,
  };
  final pages = await _tag.url
      .crawl<Post>(
        onResponse: (ctx) {
          for (final a in ctx.html.$('h2.post-box-title a')) {
            ctx.emit((title: a.text.trim(), url: a.link));
          }
          ctx.html.$('.pagination a').links.forEach(ctx.follow);
        },
      )
      .show('Listing MissKon');
  final byVolume = <int, Set<Post>>{};
  for (final post in pages.expand((posts) => posts)) {
    if (_postVolume.firstMatch(post.title)?[1] case final v?) (byVolume[int.parse(v)] ??= {}).add(post);
  }
  return [
    for (final MapEntry(key: volume, value: posts) in byVolume.entries.toList()..sort((a, b) => a.key - b.key))
      for (final post in posts)
        Album(volume, post, root / _folder(official[volume], volume, post.title, edition: posts.length > 1)),
  ];
}

/// The catalog's folder for the album, else one named by the post; an [edition] says which.
String _folder(Row? album, int volume, String title, {required bool edition}) => [
  album != null ? albumFolder(album) : 'VOL ${'$volume'.padLeft(3, '0')} - ${title.filename}',
  if (edition)
    title.contains('AI Enhanced') ? '[AI Enhanced]' : '[${RegExp(r'(\d+) photos').firstMatch(title)?[1]} photos]',
].join(' ');

/// Where the ouo.io [link] leads: its two forms submitted as soon as their buttons enable.
Task<Uri> _ouo(Chrome chrome, Uri link) => Task.run('$link', (work) async {
  final page = await chrome.open(link, render: const Render(wait: Wait.dom));
  work.defer(page.close);
  // Submitted directly: the button's click handlers open ad tabs.
  for (var step = 0; step < 3 && page.url.host.startsWith('ouo.'); step++) {
    await page.wait('#btn-main:not(.disabled)');
    await page.submit('#btn-main');
  }
  if (page.url.host.startsWith('ouo.')) throw MissingException('way past ouo.io', where: '${page.url}');
  return page.url;
});

/// unrar reads `.part2.rar` on from `.part1.rar`.
bool _isFirstVolume(Path archive) => (_part.firstMatch(archive.name)?[1] ?? '1') == '1';

/// [archive] extracted into [dir] (and deleted, every part of a set) with the post's [password],
/// else with each of [_passwords].
Task<Path> _extract(Path archive, Path dir, String? password) => Task.run(archive.name, (work) async {
  for (final pw in {?password, ..._passwords}) {
    try {
      return await archive.unarchive(into: dir, password: Secret(pw), flatten: true, original: Original.delete);
    } on PasswordException {
      continue; // the next password
    }
  }
  throw PasswordException('Invalid password for $archive: none of the known ones opens it');
});

// ---- the catalog -----------------------------------------------------------------------------

const mall = 'https://puremedia.kr/mall/';
final _catalogVolume = RegExp(r'VOL\s?(\d+)');

/// `[artist] name`: the artist, then the rest.
final _artist = RegExp(r'^\s?\[([^\]]*)\]\s?(.*)$');
final _korean = RegExp('[가-힣]+');
final _footer = RegExp(r'^(MODEL|PHOTO|PRODUCE|EVENT|Model|https?://)');
final _legal = RegExp(
  '^(${['The images are for personal viewing only.', 'All images provided in the web pictorial', 'Any reproduction, retransmission, distribution or republication', '본 상품의 저작권은 퓨어미디어에 있으며', '당사는 저작권에 대하여'].map(RegExp.escape).join('|')})',
);
final _modelinsta = RegExp(r'model\s?insta', caseSensitive: false);
final _instaurl = RegExp(r'https://(www\.)?instagram\.com/\S+');
final _pics = [
  RegExp(r'총\s?(\d+)\s?(매|장|pic|PIC|Pic|컷)'),
  RegExp(r'(\d+)\s?pic', caseSensitive: false),
  RegExp(r'(\d+)\s?매'),
  RegExp(r'(\d+)\s?(장|컷)'),
];
const _boilerplate = {
  '본 상품은 디지털 웹화보 상품입니다. 바로 다운로드 가능한 상품이며 실물배송 상품이 아닙니다.',
  '구매시 디지털 상품의 특성상 구매 후 교환 환불이 불가하오니 신중히 구매해주시기 바랍니다.',
  '본 디지털 화보는 19세 미만 미성년자는 구매불가 상품이며 이를 어길 시 법적인 처벌을 받을 수 있습니다.',
  'Legal Disclaimer',
};
const _trailer = {'상품정보고시', '제품명'};

String? _meta(Html doc, String property) => doc.$('meta[property="$property"]').attrs('content').firstOrNull?.trim();

String? _spec(Html doc, String label) =>
    doc.$('table.tb_gosi th:contains($label) + td').texts.map((t) => t.trim()).where((t) => t.isNotEmpty).firstOrNull;

List<String> _lines(Html doc) => doc.$('table.goods_tap').firstOrNull?.next?.lines ?? const [];

List<String> _concept(Html doc) {
  final lines = _lines(doc);
  final cut = lines.indexWhere(_trailer.contains);
  return [
    for (final line in lines.take(cut < 0 ? lines.length : cut))
      if (!_boilerplate.contains(line) && !line.startsWith('!') && !_footer.hasMatch(line) && !_legal.hasMatch(line))
        line,
  ];
}

String? _instagram(Html doc) {
  final lines = _lines(doc);
  final label = lines.indexWhere(_modelinsta.hasMatch);
  for (final line in lines.skip(label + 1).take(label < 0 ? 0 : 3)) {
    if (_instaurl.firstMatch(line)?[0] case final url?) return url;
  }
  return doc.$('a[href*="instagram.com"]').attrs('href').lastOrNull;
}

Map<String, Object?> _album(Html doc, Uri url) {
  final title = _meta(doc, 'og:title') ?? doc.$('div.goodsName').first.text;
  final matched = _artist.firstMatch(title);
  final concept = _concept(doc).join('\n');
  return {
    'id': int.tryParse(url.queryParameters['ps_goid'] ?? '') ?? 0,
    'volume': _catalogVolume.firstMatch(title)?[1]?.to<int>(),
    'artist': matched?[1]?.trim(),
    'name': _korean.firstMatch(matched?[2] ?? title)?[0],
    'title': title,
    'subtitle': _meta(doc, 'og:description'),
    'pics': _pics.map((r) => r.firstMatch(concept)?[1]).nonNulls.firstOrNull?.to<int>(),
    'concept': concept,
    'instagram': _instagram(doc),
    'price': _spec(doc, '판매가격'),
    'brand': _spec(doc, '브랜드'),
    'origin': _spec(doc, '원산지'),
    'manufacturer': _spec(doc, '제조사'),
    'rating': doc.$('img[src*="icon_star.png"]').length,
    'image': _meta(doc, 'og:image'),
    'url': '$url',
  };
}

/// The detail pages [pages] link to.
Future<Set<String>> _links(Iterable<String> pages) async => {
  for (final doc in await pages.parallelize((page) => page.url.get().html).show('Listing puremedia.kr'))
    for (final link in doc.$('a[href*="m_mall_detail"]'))
      if (link.link.queryParameters['ps_goid'] case final goid?) '${mall}m_mall_detail.php?ps_goid=$goid',
};

/// Each album [links] lead to, into [into] by id; one that failed is said and counted.
Future<void> _crawl(Set<String> links, Map<int, Map<String, Object?>> into) async {
  final albums = links
      .parallelize((link) async => _album(await link.url.get().html, link.url))
      .progress('puremedia.kr');
  await for (final album in albums.values) {
    into[album['id']! as int] = album;
  }
}

List<int> _missing(Map<int, Map<String, Object?>> albums) {
  final seen = albums.values.map((a) => a['volume'] as int?).nonNulls.toSet();
  return [
    for (var v = 1; v <= seen.fold(0, max); v++)
      if (!seen.contains(v)) v,
  ];
}

/// `VOL 007 - <artist> <name> (<id>)`: the name of an album's folder.
String albumFolder(Map<String, Object?> album) {
  final [volume, artist, name] = [album['volume'], album['artist'], album['name']];
  final label = {?artist, ?name}.join(' ');
  final prefix = volume is int ? 'VOL ${'$volume'.padLeft(3, '0')}' : 'NO_VOL';
  return '$prefix - ${(label.isNotEmpty ? label : '${album['title']}').filename} (${album['id']})';
}

/// The puremedia.kr catalog: read from [file], or scraped into it on the first run: the
/// listing, then a search for each volume the listing skipped.
Future<List<Row>> _catalog(Path file) async {
  if (await file.exists()) return (await Table.read(file)).rows;
  final albums = <int, Map<String, Object?>>{};
  await Http.scope(headers: {'accept-language': 'ko-KR'}, delay: 250.ms, () async {
    var links = await _links([for (var page = 1; page <= 3; page++) '${mall}m_mall_list.php?ps_page=$page']);
    final seen = {...links};
    for (var round = 0; round < 3 && links.isNotEmpty; round++) {
      await _crawl(links, albums);
      links = {
        for (final link in await _links([for (final v in _missing(albums)) '${mall}m_search.php?ps_search=$v']))
          if (seen.add(link)) link,
      };
    }
  });
  final table = Table.rows(albums.values.toList()..sort((a, b) => _order(a).compareTo(_order(b))));
  await table.save(file);
  return table.rows;
}

int _order(Map<String, Object?> album) => album['volume'] as int? ?? 1 << 30;
