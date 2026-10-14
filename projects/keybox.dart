// Downloads the Key BOX -for two decades- set (artwork, scans, messages and the mp3
// soundtrack) into the folder below, then zips it. Files already there are skipped.
//
//   dart run projects/keybox.dart
library;

import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/pool.dart';

const site = 'https://key.visualarts.gr.jp/key20th/';
const soundtrack = 'https://downloads.khinsider.com/game-soundtracks/album/key-box-for-two-decades-2019';
const scans = 'https://jetta.vgmtreasurechest.com/soundtracks/key-box-for-two-decades-2019';
const formats = ['mp3'];
const browserHeaders = {
  'accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
  'accept-language': 'en-US,en;q=0.9',
  'upgrade-insecure-requests': '1',
};

final box = Fs.dir('Key BOX -for two decades- (2019)');
final keyBoxArt = box.dir('Others').dir('KeyBOX');
final anniversary = box.dir('Others').dir('Key 20th Anniversary');
final events = box.dir('Others').dir('Events & Topics');
final tributes = box.dir('Others').dir('Messages & Tributes');

final discNumber = RegExp(r'DISC\.?(\d+)');
final trackLine = RegExp(r'^(\d+)\.(.*)$');
final discInLink = RegExp(r'/(\d+)-');
final trackInLink = RegExp(r'-(\d+)\.');
final number = RegExp(r'(\d+)');

/// One file to fetch, and where it goes.
typedef Asset = (String url, File to);

final class Disc {
  Disc(this.name, this.tracks);
  final String name;
  final Map<int, String> tracks;
  Dir get folder => box.dir(name);
  File track(int number, String title, String format) => folder.dir(format).file('$number. $title.$format');
}

Future<void> main() async {
  final keyBox = await page('${site}key_box.html');
  final discs = readDiscs(keyBox);
  final assets = [
    ...discArtwork(keyBox, discs),
    ...boxArtwork(),
    ...messages(await page('${site}message.html')),
    ...topics(await page('${site}topics.html')),
    ...await songs(discs),
  ];
  final missing = <Asset>[];
  for (final asset in assets) {
    if (!await asset.$2.exists()) missing.add(asset);
  }
  final bar = Console.bar(missing.length, label: 'Downloading');
  await Pool.map(missing, (a) async => await (get(a.$1) > a.$2), onResult: (_) => bar.tick());
  await Console.spin('Zipping', (Archive.archive(['.'], dir: box.path()) > Fs.file('${box.path()}.zip')));
}

Future<Response> get(String url) =>
    Http.get(url, headers: browserHeaders, timeout: const Duration(seconds: 60), retries: 3);

Future<Elements> page(String url) => get(url).html();

String nameOf(String url) => Uri.parse(url).pathSegments.last;

Map<int, Disc> readDiscs(Elements page) {
  final discs = <int, Disc>{};
  for (final item in page.$('.key_cd_track_box ul li')) {
    final title = item.$('.track_disc_title').text();
    if (title.isEmpty) continue;
    final match = discNumber.firstMatch(title);
    if (match == null) continue;
    final disc = int.parse(match[1]!);
    final tracks = <int, String>{};
    for (final line in item.$('.track_disc_text_style1').text().split('\n')) {
      if (trackLine.firstMatch(line.trim()) case final m?) {
        tracks[int.parse(m[1]!)] = Fs.sanitize(disc == 22 && m[1] == '13' ? '小さなてのひら' : m[2]!);
      }
    }
    discs[disc] = Disc(Fs.sanitize(title), tracks);
  }
  return discs;
}

List<Asset> discArtwork(Elements page, Map<int, Disc> discs) {
  final out = <Asset>[];
  for (final item in page.$('.key_cd_artworks_box')) {
    final url = item.$('a').attr('href');
    if (url == null) continue;
    final text = item.text();
    if (discNumber.firstMatch(text)?[1] case final disc?) {
      final folder = discs[int.parse(disc)];
      if (folder == null) continue;
      out.add((url, folder.folder.file(nameOf(url))));
    } else if (text.contains('ALL')) {
      out.add((url, keyBoxArt.file(nameOf(url))));
    }
  }
  return out;
}

List<Asset> boxArtwork() {
  final singers = 'kai tanaka minami na-ga suzukikeiko sakurai kohara orito suzuki yurika'.split(' ');
  Asset image(String name, Dir folder) => ('${site}common/image/${name.split('/').last}', folder.file(name));
  return [
    ('${site}common/album_jacket/keybox_image.png', keyBoxArt.file('keybox_image.png')),
    ('$scans/00%20Contents.jpg', keyBoxArt.file('00_Contents.jpg')),
    ('$scans/01%20Box%20sample.png', keyBoxArt.file('01_Box_sample.png')),
    for (final name in [
      '20th_box_image.jpg',
      'key_box_main_image.png',
      'sp_key_box_main_image.png',
      'key_box_bg.jpg',
      'key_box_onsale_title3.jpg',
      'sp_20th_banner_keybox.png',
    ])
      image(name, keyBoxArt),
    for (final name in [
      '20th_main_image.jpg',
      '20th_main_bg.jpg',
      '20th_top_main_banner_1.png',
      '20th_menu_logo.png',
      'sp_20th_top_title.png',
      'sp_20th_main_image_1.jpg',
      'sp_20th_main_image_2.jpg',
      'sp_20th_main_image_3.jpg',
    ])
      image(name, anniversary),
    for (final name in [
      'Stamp Rally/key20th_stamp_poster_1.jpg',
      'Stamp Rally/key20th_stamp_poster_1_a.jpg',
      'movie_image_0712.jpg',
      'history_image_50.jpg',
      'topics_image_20191217_2.jpg',
      for (var i = 1; i <= 8; i++) 'General Election/key_election_$i.jpg',
      for (final singer in singers) 'Live Streams/profile_$singer.jpg',
    ])
      image(name, events),
  ];
}

List<Asset> messages(Elements page) {
  const groups = ['Anime Staff', 'Voice Cast', 'Guest Tributes', 'Key Staff & Creators'];
  final out = <Asset>[];
  final sections = page.$('.message_white_box').take(groups.length).toList();
  for (var g = 0; g < sections.length; g++) {
    var i = 0;
    for (final a in sections[g].$('a[href*="message_"]')) {
      final url = a.attr('href');
      if (url == null) continue;
      i++;
      final title = a.attr('title') ?? a.text().replaceAll('[New Message]', '');
      out.add((url, tributes.dir(groups[g]).file('${studio(url)}${'$i'.padLeft(2, '0')}_${Fs.sanitize(title)}.jpg')));
    }
  }
  return out;
}

String studio(String url) => url.contains('wfs') ? 'WFS_' : (url.contains('cygames') ? 'Cygames_' : '');

List<Asset> topics(Elements page) {
  final out = <Asset>[];
  for (final image in page.$('.topics_box img')) {
    final src = image.attr('src');
    if (src == null) continue;
    out.add((src, events.file(nameOf(src))));
  }
  return out;
}

/// The soundtrack's song pages, then each page's file link for every format not on disk yet.
Future<List<Asset>> songs(Map<int, Disc> discs) async {
  final doc = await page(soundtrack);
  final wanted = <(String, Map<String, File>)>[];
  for (final row in doc.$('#songlist tr')) {
    final cells = row.$('td').toList();
    if (cells.length < 4) continue;
    final song = cells[3].$('a').attr('href');
    if (song == null) continue;
    final path = Uri.parse(song).path;
    final disc = discs[numberIn(path, discInLink, orIn: cells[1].text())];
    if (disc == null) continue;
    final track = numberIn(path, trackInLink, orIn: cells[2].text());
    final title = disc.tracks[track] ?? Fs.sanitize(cells[3].text());
    final missing = <String, File>{};
    for (final format in formats) {
      final to = disc.track(track, title, format);
      if (!await to.exists()) missing[format] = to;
    }
    if (missing.isNotEmpty) wanted.add((song, missing));
  }
  final bar = Console.bar(wanted.length, label: 'Song pages');
  final found = await Pool.map(wanted, songFiles, onResult: (_) => bar.tick());
  return found.expand((files) => files).toList();
}

/// One song page's file links.
Future<List<Asset>> songFiles((String, Map<String, File>) song) async {
  final doc = await page(song.$1);
  final out = <Asset>[];
  for (final entry in song.$2.entries) {
    final url = doc.$('a[href*=".${entry.key}"]').attr('href');
    if (url != null) out.add((url, entry.value));
  }
  return out;
}

int numberIn(String path, RegExp pattern, {required String orIn}) =>
    int.parse(pattern.firstMatch(path)?[1] ?? number.firstMatch(orIn)![1]!);
