import 'package:dart_toolkit/dart_toolkit.dart';

const keyBase = 'https://key.visualarts.gr.jp/key20th/';
const khinsider = 'https://downloads.khinsider.com/game-soundtracks/album/key-box-for-two-decades-2019';
const baseName = 'Key BOX -for two decades- (2019)';

void main() async {
  onExit(() => Logger.warn('Interrupted.'));

  final base = baseName.path;
  final baseUri = keyBase.url;
  final downloads = <Path, Uri>{};
  final discNames = <int, String>{};
  final tracks = <int, Map<int, String>>{};

  // 1. Scrape official metadata & images
  final doc = await (baseUri / 'key_box.html').html();
  for (final li in doc.$('.key_cd_track_box ul li')) {
    final title = li.$('.track_disc_title').first.text.path.sanitized();
    final d = int.parse(title.match(r'DISC\.(\d+)', 1)!);
    discNames[d] = title;
    tracks[d] = {
      for (final line in li.$('.track_disc_text_style1').first.lines)
        if (RegExp(r'^(\d+)\.(.*)$').firstMatch(line) case final m?)
          int.parse(m[1]!): (d == 22 && m[1] == '13') ? '小さなてのひら' : m[2]!.trim(),
    };
  }

  for (final e in doc.$('.key_cd_artworks_box')) {
    final d = int.parse(e.text.replaceAll(RegExp(r'\D'), ''));
    final href = e.$('a').first.attr('href')!;
    downloads[base / discNames[d]! / href.path.name] = baseUri / href;
  }

  downloads.addAll({
    base / 'Others/KeyBOX/keybox_image.png': baseUri / 'common/album_jacket/keybox_image.png',
    for (final n in [
      '20th_box_image.jpg', 'key_box_main_image.png', 'sp_key_box_main_image.png',
      'key_box_bg.jpg', 'key_box_onsale_title3.jpg', 'sp_20th_banner_keybox.png',
    ]) base / 'Others/KeyBOX' / n: baseUri / 'common/image/$n',
    base / 'Others/KeyBOX/00_Contents.jpg': 'https://jetta.vgmtreasurechest.com/soundtracks/key-box-for-two-decades-2019/00%20Contents.jpg'.url,
    base / 'Others/KeyBOX/01_Box_sample.png': 'https://jetta.vgmtreasurechest.com/soundtracks/key-box-for-two-decades-2019/01%20Box%20sample.png'.url,
    for (final n in [
      '20th_main_image.jpg', '20th_main_bg.jpg', '20th_top_main_banner_1.png',
      '20th_menu_logo.png', 'sp_20th_top_title.png', 'sp_20th_main_image_1.jpg',
      'sp_20th_main_image_2.jpg', 'sp_20th_main_image_3.jpg',
    ]) base / 'Others/Key 20th Anniversary' / n: baseUri / 'common/image/$n',
    base / 'Others/Events & Topics/Stamp Rally/key20th_stamp_poster_1.jpg': baseUri / 'common/image/key20th_stamp_poster_1.jpg',
    base / 'Others/Events & Topics/Stamp Rally/key20th_stamp_poster_1_a.jpg': baseUri / 'common/image/key20th_stamp_poster_1_a.jpg',
    for (final n in ['movie_image_0712.jpg', 'history_image_50.jpg', 'topics_image_20191217_2.jpg'])
      base / 'Others/Events & Topics' / n: baseUri / 'common/image/$n',
    for (var i = 1; i <= 8; i++)
      base / 'Others/Events & Topics/General Election/key_election_$i.jpg': baseUri / 'common/image/key_election_$i.jpg',
    for (final n in ['kai', 'tanaka', 'minami', 'na-ga', 'suzukikeiko', 'sakurai', 'kohara', 'orito', 'suzuki', 'yurika'])
      base / 'Others/Events & Topics/Live Streams/profile_$n.jpg': baseUri / 'common/image/profile_$n.jpg',
  });

  final msgDoc = await (baseUri / 'message.html').html();
  const categories = ['Anime Staff', 'Voice Cast', 'Guest Tributes', 'Key Staff & Creators'];
  for (final (i, box) in msgDoc.$('.message_white_box').take(4).indexed) {
    for (final (n, a) in box.$('a[href*="message_"]').indexed) {
      final href = a.attr('href')!;
      final tag = href.contains('wfs') ? 'WFS_' : href.contains('cygames') ? 'Cygames_' : '';
      final pfx = '${n + 1}'.padLeft(2, '0');
      final name = (a.attr('title') ?? a.text.replaceAll('[New Message]', '')).path.sanitized();
      downloads[base / 'Others/Messages & Tributes/${categories[i]}/$tag${pfx}_$name.jpg'] = baseUri / href;
    }
  }

  final topicsDoc = await (baseUri / 'topics.html').html();
  for (final img in topicsDoc.$('.topics_box img')) {
    if (img.attr('src') case final src?) {
      downloads[base / 'Others/Events & Topics' / src.path.name] = baseUri / src;
    }
  }

  // 2. Scrape audio tracks
  final audioStream = khinsider.url.scrape<({Path path, Uri url})>((res) async {
    for (final tr in res.$('#songlist tr')) {
      final tds = tr.$('td');
      if (tds.length < 4) continue;
      final href = tds[3].$('a').first.attr('href')!;
      final d = int.parse(href.match(r'\/(\d+)-', 1) ?? tds[1].text.replaceAll(RegExp(r'\D'), ''));
      final t = int.parse(href.match(r'-(\d+)\.', 1) ?? tds[2].text.replaceAll(RegExp(r'\D'), ''));
      final disc = discNames[d]!;
      final title = (tracks[d]?[t] ?? tds[3].text).path.sanitized();

      for (final ext in const ['mp3', 'flac']) {
        final target = base / disc / ext / '$t. $title.$ext';
        if (!await target.exist()) {
          res.follow(href, callback: (songRes) {
            final dlHref = songRes.$('a[href*=".$ext"]').first.attr('href')!;
            songRes.emit((path: target, url: (songRes.url ?? khinsider.url).resolve(dlHref)));
          });
        }
      }
    }
  }, concurrency: 4);

  await for (final item in audioStream) {
    downloads[item.path] = item.url;
  }

  // 3. Download
  final progress = Console.progress(downloads.length, message: 'Downloading');
  await for (final status in downloads.downloadAll(concurrency: 4)) {
    if (status.current.isDone) progress.tick(1, status.current.path.name);
  }
  progress.done('All assets downloaded.');

  // 4. Archive
  await Console.spin('Compressing $baseName.zip...', () => base.zip('$baseName.zip'));
  Logger.ok('Done.');
}
