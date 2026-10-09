import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/collection.dart';
import 'package:dart_toolkit/scrape.dart';

final site = 'https://key.visualarts.gr.jp/key20th/'.url;
const soundtrack = 'https://downloads.khinsider.com/game-soundtracks/album/key-box-for-two-decades-2019';
const scans = 'https://jetta.vgmtreasurechest.com/soundtracks/key-box-for-two-decades-2019';
const formats = ['mp3'];

final box = Path.here.parent / 'Key BOX -for two decades- (2019)';

final discNumber = RegExp(r'DISC\.?(\d+)');
final trackLine = RegExp(r'^(\d+)\.(.*)$');
final discInLink = RegExp(r'/(\d+)-');
final trackInLink = RegExp(r'-(\d+)\.');
final number = RegExp(r'(\d+)');

const browserHeaders = {
  'accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
  'accept-language': 'en-US,en;q=0.9',
  'upgrade-insecure-requests': '1',
};

typedef Asset = ({Uri url, Path to});

final class Disc {
  final String name;
  final Map<int, String> tracks;

  Disc(this.name, this.tracks);

  Path get folder => box / name;

  Path track(int number, String title, String format) => folder / format / '$number. $title.$format';
}

void main(List<String> args) => Cli(
  'Downloads the Key BOX -for two decades- set and zips it.',
  handler: (ctx) => Http.scope(downloadBox, timeout: 60.s, retry: Retry(3), perHost: 4, headers: browserHeaders),
).run(args);

Future<void> downloadBox() async {
  final began = Clock.current.elapsed;

  Console.rule('Reading the official site');
  final keyBox = await read('key_box.html');
  final discs = readDiscs(keyBox);
  final artwork = [
    ...discArtwork(keyBox, discs),
    ...boxArtwork(),
    ...messages(await read('message.html')),
    ...topics(await read('topics.html')),
  ];
  Console.info('${discs.length} discs and ${artwork.length} images');

  Console.rule('Downloading');
  final songs = soundtrack.url.crawl<Asset>(onResponse: (page) => findSongs(page, discs));
  songs.progress('Song pages');
  final downloads = Batch.merge([artwork.parallelize(save), songs.items.parallelize(save)]);
  final files = await downloads.show('Downloading', done: 'Everything is here.');
  await songs;

  Console.rule('Zipping');
  final zip = await box.archive(to: '$box.zip', conflict: Conflict.overwrite).show('Zipping', done: 'Zipped.');

  final newFiles = (await downloads.settled).whereType<Done<Asset, Path>>().where((done) => done.fresh).length;
  Table.cells(
    ['Result', 'Value'],
    [
      ['Discs', discs.length],
      ['Files', files.length],
      ['New this run', newFiles],
      ['Archive', '${zip.name} (${(await zip.size()).humanBytes})'],
      ['Time', (Clock.current.elapsed - began).humanized],
    ],
  ).show();
}

Future<Html> read(String page) async => (await (site / page).get().show('Reading $page')).html;

Task<Path> save(Asset asset) => asset.url.download(to: asset.to);

Asset asset(String href, Path to) => (url: site / href, to: to);

Map<int, Disc> readDiscs(Html page) {
  final discs = <int, Disc>{};
  for (final item in page.$('.key_cd_track_box ul li')) {
    final title = item.$('.track_disc_title').text;
    final disc = int.parse(discNumber.firstMatch(title)![1]!);
    final tracks = <int, String>{};
    for (final line in item.$('.track_disc_text_style1').first.lines) {
      if (trackLine.firstMatch(line) case final match?) {
        final track = int.parse(match[1]!);
        tracks[track] = trackTitle(disc, track, match[2]!).filename;
      }
    }
    discs[disc] = Disc(title.filename, tracks);
  }
  return discs;
}

String trackTitle(int disc, int track, String title) => disc == 22 && track == 13 ? '小さなてのひら' : title;

List<Asset> discArtwork(Html page, Map<int, Disc> discs) {
  final assets = <Asset>[];
  for (final item in page.$('.key_cd_artworks_box')) {
    final href = item.$('a').attr('href');
    final name = (site / href).name;
    if (discNumber.firstMatch(item.text)?[1] case final disc?) {
      assets.add(asset(href, discs[int.parse(disc)]!.folder / name));
    } else if (item.text.contains('ALL')) {
      assets.add(asset(href, box / 'Others/KeyBOX' / name));
    }
  }
  return assets;
}

List<Asset> boxArtwork() {
  final keyBox = box / 'Others/KeyBOX';
  final anniversary = box / 'Others/Key 20th Anniversary';
  final events = box / 'Others/Events & Topics';
  final singers = 'kai tanaka minami na-ga suzukikeiko sakurai kohara orito suzuki yurika'.split(' ');

  Asset image(String name, Path folder) => asset('common/image/${name.url.name}', folder / name);

  return [
    asset('common/album_jacket/keybox_image.png', keyBox / 'keybox_image.png'),
    asset('$scans/00%20Contents.jpg', keyBox / '00_Contents.jpg'),
    asset('$scans/01%20Box%20sample.png', keyBox / '01_Box_sample.png'),
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

List<Asset> messages(Html page) {
  const groups = ['Anime Staff', 'Voice Cast', 'Guest Tributes', 'Key Staff & Creators'];
  final assets = <Asset>[];
  for (final (group, section) in page.$('.message_white_box').take(groups.length).indexed) {
    for (final (i, link) in section.$('a[href*="message_"]').indexed) {
      final href = link.attr('href');
      final studio = href.contains('wfs') ? 'WFS_' : (href.contains('cygames') ? 'Cygames_' : '');
      final position = '${i + 1}'.padLeft(2, '0');
      final author = (link.attributes['title'] ?? link.text.replaceAll('[New Message]', '')).filename;
      final folder = box / 'Others/Messages & Tributes' / groups[group];
      assets.add(asset(href, folder / '$studio${position}_$author.jpg'));
    }
  }
  return assets;
}

List<Asset> topics(Html page) => [
  for (final image in page.$('.topics_box img'))
    asset(image.attr('src'), box / 'Others/Events & Topics' / (site / image.attr('src')).name),
];

Future<void> findSongs(ResponseContext<Asset> page, Map<int, Disc> discs) async {
  for (final row in page.html.$('#songlist tr')) {
    final cells = row.$('td').toList();
    if (cells.length < 4) continue;
    final link = cells[3].$('a').link;
    final disc = numberIn(link.path, discInLink, orIn: cells[1].text);
    final track = numberIn(link.path, trackInLink, orIn: cells[2].text);
    final title = discs[disc]!.tracks[track] ?? cells[3].text.filename;

    final missing = <String, Path>{};
    for (final format in formats) {
      final file = discs[disc]!.track(track, title, format);
      if (!await file.exists()) missing[format] = file;
    }
    if (missing.isEmpty) continue;

    page.follow(link, onResponse: (song) => findFiles(song, missing));
  }
}

int numberIn(String link, RegExp pattern, {required String orIn}) =>
    int.parse(pattern.firstMatch(link)?[1] ?? number.firstMatch(orIn)![1]!);

void findFiles(ResponseContext<Asset> song, Map<String, Path> missing) {
  for (final MapEntry(key: format, value: file) in missing.entries) {
    final links = song.html.$('a[href*=".$format"]').links;
    if (links.isNotEmpty) song.emit((url: links.first, to: file));
  }
}
