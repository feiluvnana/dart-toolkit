// Downloads the Key BOX -for two decades- set (artwork, scans, messages and the
// mp3 soundtrack), then zips it. Files already downloaded are skipped.
//
//   dart run projects/keybox/keybox.dart
library;

import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/html.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/pool.dart';
import 'package:dart_toolkit/utils.dart';

const site = 'https://key.visualarts.gr.jp/key20th/';
const soundtrack = 'https://downloads.khinsider.com/game-soundtracks/album/key-box-for-two-decades-2019';
const scans = 'https://jetta.vgmtreasurechest.com/soundtracks/key-box-for-two-decades-2019';
final http = Http.client(headers: HttpUtils.page, timeout: 60.seconds, resume: true);

final box = Fs.scriptDir() / 'Key BOX -for two decades- (2019)';
final keyBoxArt = box / 'Others/KeyBOX';
final anniversary = box / 'Others/Key 20th Anniversary';
final events = box / 'Others/Events & Topics';
final tributes = box / 'Others/Messages & Tributes';

final discNumber = RegExp(r'DISC\.?(\d+)');
final trackLine = RegExp(r'^(\d+)\.(.*)$');
final discInLink = RegExp(r'/(\d+)-');
final trackInLink = RegExp(r'-(\d+)\.');
final number = RegExp(r'(\d+)');

typedef Asset = (String url, Writer to); // a file, or a folder that takes the server's name

final class Disc {
  Disc(this.name, this.tracks);
  final String name;
  final Map<int, String> tracks;
  Dir get folder => box / name;
  File track(int number, String title) => (folder / 'mp3').file('$number. $title.mp3');
}

Future<void> main(List<String> args) =>
    Command('keybox', 'Download the Key BOX set into "${box.path}" and zip it.', handler: (_) => download()).run(args);

Future<void> download() async {
  final (keyBox, messagePage, topicsPage) =
      await ((page('${site}key_box.html'), page('${site}message.html'), page('${site}topics.html')).wait &
          Console.bar('reading the Key 20th site'));
  final discs = readDiscs(keyBox);
  final assets = [
    ...discArtwork(keyBox, discs),
    ...boxArtwork(),
    ...messages(messagePage),
    ...topics(topicsPage),
    ...await songs(discs),
  ];

  await (Pool.map(assets, (a) async {
        final (url, to) = a;
        await (http.get(url) & Console.bar('', keep: false) > to);
      }) &
      Console.bar('files done'));
  final zip = Fs.file('${box.path}.zip');
  await (Archive.archive(['.'], dir: box.path) & Console.bar('zipping into ${zip.path}') > zip);
  Console.log('done: ${discs.length} discs and ${assets.length} files in "${box.path}", zipped to "${zip.path}"');
}

Future<Elements> page(String url) => http.get(url).html();

Map<int, Disc> readDiscs(Elements page) => {
  for (final item in page.$('.key_cd_track_box ul li'))
    if (discNumber.firstMatch(item.$('.track_disc_title').text())?[1] case final d?)
      int.parse(d): Disc(
        Fs.sanitize(item.$('.track_disc_title').text()),
        {
          for (final line in item.$('.track_disc_text_style1').text().split('\n'))
            if (trackLine.firstMatch(line.trim()) case final m?)
              int.parse(m[1]!): Fs.sanitize(d == '22' && m[1] == '13' ? '小さなてのひら' : m[2]!),
        },
      ),
};

List<Asset> discArtwork(Elements page, Map<int, Disc> discs) => [
  for (final item in page.$('.key_cd_artworks_box'))
    if (item.$('a').attr('href') case final url?)
      if (discNumber.firstMatch(item.text())?[1] case final d?) ...[
        if (discs[int.parse(d)] case final disc?) (url, disc.folder),
      ] else if (item.text().contains('ALL')) ...[
        (url, keyBoxArt),
      ],
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

List<Asset> messages(Elements page) {
  const groups = ['Anime Staff', 'Voice Cast', 'Guest Tributes', 'Key Staff & Creators'];
  Asset tribute(String group, int i, Element a) {
    final url = a.attr('href')!;
    final title = a.attr('title') ?? a.text().replaceAll('[New Message]', '');
    return (url, (tributes / group).file('${studio(url)}${'${i + 1}'.padLeft(2, '0')}_${Fs.sanitize(title)}.jpg'));
  }

  return [
    for (final (g, section) in page.$('.message_white_box').take(groups.length).indexed)
      for (final (i, a) in section.$('a[href*="message_"]').indexed) tribute(groups[g], i, a),
  ];
}

String studio(String url) => url.contains('wfs') ? 'WFS_' : (url.contains('cygames') ? 'Cygames_' : '');

List<Asset> topics(Elements page) => [for (final src in page.$('.topics_box img').attrs('src')) (src, events)];

// khinsider has one page per song; the actual file link is on that page.
Future<List<Asset>> songs(Map<int, Disc> discs) async {
  final doc = await (page(soundtrack) & Console.bar('reading the soundtrack list'));
  final wanted = <Asset>[]; // (the song's page, its file)
  for (final row in doc.$('#songlist tr')) {
    final cells = row.$('td').toList();
    if (cells.length < 4) continue;
    final song = cells[3].$('a').attr('href');
    if (song == null) continue;
    final path = Uri.parse(song).path;
    final disc = discs[numberIn(path, discInLink, orIn: cells[1].text())];
    if (disc == null) continue;
    final track = numberIn(path, trackInLink, orIn: cells[2].text());
    final to = disc.track(track, disc.tracks[track] ?? Fs.sanitize(cells[3].text()));
    if (!await to.exists()) wanted.add((song, to));
  }
  final found = await (Pool.map(wanted, songFile) & Console.bar('finding song files'));
  return found.nonNulls.toList();
}

Future<Asset?> songFile(Asset song) async {
  final url = (await page(song.$1)).$('a[href*=".mp3"]').attr('href');
  return url == null ? null : (url, song.$2);
}

int numberIn(String path, RegExp pattern, {required String orIn}) =>
    int.parse(pattern.firstMatch(path)?[1] ?? number.firstMatch(orIn)![1]!);
