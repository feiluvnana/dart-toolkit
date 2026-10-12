// Downloads the Key BOX -for two decades- set (artwork, scans, messages and the mp3
// soundtrack) next to this script, then zips it. Files already there are skipped.
//
//   dart run example/keybox/keybox.dart
library;

import 'dart:async';
import 'dart:io' as io;

import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/async.dart';
import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/path.dart';

const site = 'https://key.visualarts.gr.jp/key20th/';
const soundtrack = 'https://downloads.khinsider.com/game-soundtracks/album/key-box-for-two-decades-2019';
const scans = 'https://jetta.vgmtreasurechest.com/soundtracks/key-box-for-two-decades-2019';
const formats = ['mp3'];
const browserHeaders = {
  'accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
  'accept-language': 'en-US,en;q=0.9',
  'upgrade-insecure-requests': '1',
};

final here = File(io.Platform.script.toFilePath()).parent;
final box = here.dir('Key BOX -for two decades- (2019)');

final discNumber = RegExp(r'DISC\.?(\d+)');
final trackLine = RegExp(r'^(\d+)\.(.*)$');
final discInLink = RegExp(r'/(\d+)-');
final trackInLink = RegExp(r'-(\d+)\.');
final number = RegExp(r'(\d+)');

/// One file to fetch: plain strings, so it crosses into a Pool worker.
typedef Asset = ({String url, String to});

final class Disc {
  Disc(this.name, this.tracks);
  final String name;
  final Map<int, String> tracks;
  Dir get folder => box.dir(name);
  File track(int number, String title, String format) => folder.dir(format).file('$number. $title.$format');
}

Future<void> main() async {
  final clock = Stopwatch()..start();

  Cli.print('Reading the official site'.bold);
  final Doc keyBox;
  try {
    keyBox = await page('key_box.html');
  } on Exception catch (e) {
    // The first request decides whether the site is there at all: say so plainly.
    io.stderr.writeln("✗ Can't reach ${Uri.parse(site).host}: $e");
    io.exitCode = 1;
    return;
  }
  final discs = readDiscs(keyBox);
  final artwork = [
    ...discArtwork(keyBox, discs),
    ...boxArtwork(),
    ...messages(await page('message.html')),
    ...topics(await page('topics.html')),
  ];
  Cli.print('${discs.length} discs and ${artwork.length} images');

  final pool = Pool(4);
  Cli.print('Finding the songs'.bold);
  final songs = await findSongs(discs, pool);

  final assets = [...artwork, ...songs];
  final missing = [
    for (final asset in assets)
      if (!await File(asset.to).exists()) asset,
  ];
  Cli.print('Downloading ${missing.length} of ${assets.length} files'.bold);
  final bar = Cli.bar(missing.length, label: 'Downloading');
  await Future.wait([for (final asset in missing) pool.run(bind(save, asset)).then((_) => bar.tick())]);
  bar.close();
  await pool.close();

  Cli.print('Zipping'.bold);
  final zip = File('${box.path}.zip');
  await box.pack(zip);

  for (final (label, value) in [
    ('Discs', '${discs.length}'),
    ('Files', '${assets.length}'),
    ('New this run', '${missing.length}'),
    ('Archive', '${zip.name} (${sizeText(await zip.size())})'),
    ('Time', timeText(clock.elapsed)),
  ]) {
    Cli.print('${label.padRight(14)}$value');
  }
}

Request get(String url) => Http.get(url, headers: browserHeaders, timeout: const Duration(seconds: 60), retry: 3);

Future<Doc> page(String name) => get(link(site, name)).html();

/// Fetches [asset] into place. Runs on a Pool worker: it uses only its argument and constants.
Future<void> save(Asset asset) async {
  final to = File(asset.to);
  await to.parent.make();
  await get(asset.url).pipe(to);
}

Asset asset(String href, File to) => (url: link(site, href), to: to.path);

String nameOf(String href) => Uri.parse(link(site, href)).pathSegments.last;

Map<int, Disc> readDiscs(Doc page) {
  final discs = <int, Disc>{};
  for (final item in page.all('.key_cd_track_box ul li')) {
    final title = item.find('.track_disc_title')!.text;
    final disc = int.parse(discNumber.firstMatch(title)![1]!);
    final tracks = <int, String>{};
    for (final line in lines(item.find('.track_disc_text_style1')!)) {
      if (trackLine.firstMatch(line) case final match?) {
        final track = int.parse(match[1]!);
        tracks[track] = safeName(trackTitle(disc, track, match[2]!));
      }
    }
    discs[disc] = Disc(safeName(title), tracks);
  }
  return discs;
}

String trackTitle(int disc, int track, String title) => disc == 22 && track == 13 ? '小さなてのひら' : title;

List<Asset> discArtwork(Doc page, Map<int, Disc> discs) => [
  for (final item in page.all('.key_cd_artworks_box'))
    if (item.find('a')?.attr('href') case final href?)
      if (discNumber.firstMatch(item.text)?[1] case final disc?)
        asset(href, discs[int.parse(disc)]!.folder.file(nameOf(href)))
      else if (item.text.contains('ALL'))
        asset(href, box.dir('Others').dir('KeyBOX').file(nameOf(href))),
];

List<Asset> boxArtwork() {
  final others = box.dir('Others');
  final keyBox = others.dir('KeyBOX');
  final anniversary = others.dir('Key 20th Anniversary');
  final events = others.dir('Events & Topics');
  final singers = 'kai tanaka minami na-ga suzukikeiko sakurai kohara orito suzuki yurika'.split(' ');

  Asset image(String name, Dir folder) => asset('common/image/${name.split('/').last}', folder.file(name));

  return [
    asset('common/album_jacket/keybox_image.png', keyBox.file('keybox_image.png')),
    asset('$scans/00%20Contents.jpg', keyBox.file('00_Contents.jpg')),
    asset('$scans/01%20Box%20sample.png', keyBox.file('01_Box_sample.png')),
    image('20th_box_image.jpg', keyBox),
    image('key_box_main_image.png', keyBox),
    image('sp_key_box_main_image.png', keyBox),
    image('key_box_bg.jpg', keyBox),
    image('key_box_onsale_title3.jpg', keyBox),
    image('sp_20th_banner_keybox.png', keyBox),
    image('20th_main_image.jpg', anniversary),
    image('20th_main_bg.jpg', anniversary),
    image('20th_top_main_banner_1.png', anniversary),
    image('20th_menu_logo.png', anniversary),
    image('sp_20th_top_title.png', anniversary),
    image('sp_20th_main_image_1.jpg', anniversary),
    image('sp_20th_main_image_2.jpg', anniversary),
    image('sp_20th_main_image_3.jpg', anniversary),
    image('Stamp Rally/key20th_stamp_poster_1.jpg', events),
    image('Stamp Rally/key20th_stamp_poster_1_a.jpg', events),
    image('movie_image_0712.jpg', events),
    image('history_image_50.jpg', events),
    image('topics_image_20191217_2.jpg', events),
    for (var i = 1; i <= 8; i++) image('General Election/key_election_$i.jpg', events),
    for (final singer in singers) image('Live Streams/profile_$singer.jpg', events),
  ];
}

List<Asset> messages(Doc page) {
  const groups = ['Anime Staff', 'Voice Cast', 'Guest Tributes', 'Key Staff & Creators'];
  final folder = box.dir('Others').dir('Messages & Tributes');
  return [
    for (final (group, section) in page.all('.message_white_box').take(groups.length).indexed)
      for (final (i, a) in section.all('a[href*="message_"]').indexed)
        asset(
          a.attr('href')!,
          folder
              .dir(groups[group])
              .file(
                '${studio(a.attr('href')!)}${'${i + 1}'.padLeft(2, '0')}_'
                '${safeName(a.attr('title') ?? a.text.replaceAll('[New Message]', ''))}.jpg',
              ),
        ),
  ];
}

String studio(String href) => href.contains('wfs') ? 'WFS_' : (href.contains('cygames') ? 'Cygames_' : '');

List<Asset> topics(Doc page) => [
  for (final image in page.all('.topics_box img'))
    asset(image.attr('src')!, box.dir('Others').dir('Events & Topics').file(nameOf(image.attr('src')!))),
];

/// The soundtrack's song pages, then each page's file link for every format not on disk yet.
Future<List<Asset>> findSongs(Map<int, Disc> discs, Pool pool) async {
  final album = await get(soundtrack).html();
  final wanted = <({String page, Map<String, String> missing})>[];
  for (final row in album.all('#songlist tr')) {
    final cells = row.all('td');
    if (cells.length < 4) continue;
    final href = cells[3].find('a')?.attr('href');
    if (href == null) continue;
    final songPage = link(soundtrack, href);
    final path = Uri.parse(songPage).path;
    final disc = discs[numberIn(path, discInLink, orIn: cells[1].text)]!;
    final track = numberIn(path, trackInLink, orIn: cells[2].text);
    final title = disc.tracks[track] ?? safeName(cells[3].text);
    final missing = <String, String>{
      for (final format in formats)
        if (!await disc.track(track, title, format).exists()) format: disc.track(track, title, format).path,
    };
    if (missing.isNotEmpty) wanted.add((page: songPage, missing: missing));
  }
  final bar = Cli.bar(wanted.length, label: 'Song pages');
  final found = await Future.wait([for (final song in wanted) pool.run(bind(songFiles, song)).whenComplete(bar.tick)]);
  bar.close();
  return [for (final files in found) ...files];
}

/// One song page's file links. Runs on a Pool worker.
Future<List<Asset>> songFiles(({String page, Map<String, String> missing}) song) async {
  final doc = await get(song.page).html();
  return [
    for (final MapEntry(key: format, value: to) in song.missing.entries)
      if (doc.find('a[href*=".$format"]')?.attr('href') case final href?) (url: link(song.page, href), to: to),
  ];
}

int numberIn(String path, RegExp pattern, {required String orIn}) =>
    int.parse(pattern.firstMatch(path)?[1] ?? number.firstMatch(orIn)![1]!);

/// The element's text split at `<br>` and line breaks, trimmed, blanks dropped.
List<String> lines(Element e) {
  final breaks = RegExp(r'<br\s*/?>', caseSensitive: false);
  final text = Html.parse(e.html.replaceAll(breaks, '\n')).text;
  return [
    for (final line in text.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];
}

String link(String base, String href) => Uri.parse(base).resolve(href).toString();

String safeName(String s) => s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').replaceAll(RegExp(r'\s+'), ' ').trim();

String sizeText(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

String timeText(Duration d) => d.inMinutes > 0 ? '${d.inMinutes}m ${d.inSeconds % 60}s' : '${d.inSeconds}s';

/// [f] applied to [x], as a job for a Pool worker. Built here, at the top level, so the
/// closure holds only [f] and [x], never the caller's other locals (rule 52).
FutureOr<R> Function() bind<T, R>(FutureOr<R> Function(T) f, T x) =>
    () => f(x);
