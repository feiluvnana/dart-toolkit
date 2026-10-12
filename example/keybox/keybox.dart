// Downloads the Key BOX -for two decades- set (artwork, scans, messages and the mp3
// soundtrack) next to this script, then zips it. Files already there are skipped.
//
//   dart run example/keybox/keybox.dart
library;

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

final box = Dir.script.dir('Key BOX -for two decades- (2019)');
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
  final missing = [
    for (final asset in assets)
      if (!await asset.$2.exists()) asset,
  ];
  await Task.all(missing, (a) => get(a.$1).pipe(a.$2), onProgress: Cli.bar(label: 'Downloading').set);
  await Cli.spin('Zipping', () => box.pack(File('${box.path}.zip')));
}

Request get(String url) => Http.get(url, headers: browserHeaders, timeout: const Duration(seconds: 60), retry: 3);

Future<Doc> page(String url) => get(url).html();

String nameOf(String url) => Uri.parse(url).pathSegments.last;

Map<int, Disc> readDiscs(Doc page) {
  final discs = <int, Disc>{};
  for (final item in page.all('.key_cd_track_box ul li')) {
    final title = item.find('.track_disc_title')!.text;
    final disc = int.parse(discNumber.firstMatch(title)![1]!);
    discs[disc] = Disc(File.safeName(title), {
      for (final line in item.find('.track_disc_text_style1')!.lines)
        if (trackLine.firstMatch(line) case final m?)
          int.parse(m[1]!): File.safeName(disc == 22 && m[1] == '13' ? '小さなてのひら' : m[2]!),
    });
  }
  return discs;
}

List<Asset> discArtwork(Doc page, Map<int, Disc> discs) => [
  for (final item in page.all('.key_cd_artworks_box'))
    if (item.find('a')?.link() case final url?)
      if (discNumber.firstMatch(item.text)?[1] case final disc?)
        (url, discs[int.parse(disc)]!.folder.file(nameOf(url)))
      else if (item.text.contains('ALL'))
        (url, keyBoxArt.file(nameOf(url))),
];

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

List<Asset> messages(Doc page) {
  const groups = ['Anime Staff', 'Voice Cast', 'Guest Tributes', 'Key Staff & Creators'];
  return [
    for (final (group, section) in page.all('.message_white_box').take(groups.length).indexed)
      for (final (i, a) in section.all('a[href*="message_"]').indexed)
        (
          a.link()!,
          tributes
              .dir(groups[group])
              .file(
                '${studio(a.link()!)}${'${i + 1}'.padLeft(2, '0')}_'
                '${File.safeName(a.attr('title') ?? a.text.replaceAll('[New Message]', ''))}.jpg',
              ),
        ),
  ];
}

String studio(String url) => url.contains('wfs') ? 'WFS_' : (url.contains('cygames') ? 'Cygames_' : '');

List<Asset> topics(Doc page) => [
  for (final image in page.all('.topics_box img')) (image.link('src')!, events.file(nameOf(image.link('src')!))),
];

/// The soundtrack's song pages, then each page's file link for every format not on disk yet.
Future<List<Asset>> songs(Map<int, Disc> discs) async {
  final wanted = <(String, Map<String, File>)>[];
  for (final row in (await page(soundtrack)).all('#songlist tr')) {
    final cells = row.all('td');
    if (cells.length < 4) continue;
    final song = cells[3].find('a')?.link();
    if (song == null) continue;
    final path = Uri.parse(song).path;
    final disc = discs[numberIn(path, discInLink, orIn: cells[1].text)]!;
    final track = numberIn(path, trackInLink, orIn: cells[2].text);
    final title = disc.tracks[track] ?? File.safeName(cells[3].text);
    final missing = {
      for (final format in formats)
        if (disc.track(track, title, format) case final to when !await to.exists()) format: to,
    };
    if (missing.isNotEmpty) wanted.add((song, missing));
  }
  final found = await Task.all(wanted, songFiles, onProgress: Cli.bar(label: 'Song pages').set);
  return found.expand((files) => files).toList();
}

/// One song page's file links.
Future<List<Asset>> songFiles((String, Map<String, File>) song) async {
  final doc = await page(song.$1);
  return [
    for (final MapEntry(key: format, value: to) in song.$2.entries)
      if (doc.find('a[href*=".$format"]')?.link() case final url?) (url, to),
  ];
}

int numberIn(String path, RegExp pattern, {required String orIn}) =>
    int.parse(pattern.firstMatch(path)?[1] ?? number.firstMatch(orIn)![1]!);
