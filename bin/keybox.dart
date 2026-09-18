import 'package:dart_toolkit/archive/archive.dart';
import 'package:dart_toolkit/async/async.dart';
import 'package:dart_toolkit/cli/cli.dart';
import 'package:dart_toolkit/core/core.dart';
import 'package:dart_toolkit/fs/fs.dart';
import 'package:dart_toolkit/html/html.dart';
import 'package:dart_toolkit/http/http.dart';
import 'package:dart_toolkit/util/util.dart';

const keyBase = 'https://key.visualarts.gr.jp/key20th/';
const khinsider = 'https://downloads.khinsider.com/game-soundtracks/album/key-box-for-two-decades-2019';
const baseName = 'Key BOX -for two decades- (2019)';

/// What the scrapers produce and the downloader consumes.
typedef Asset = ({Uri url, Path path});

void main(List<String> rawArgs) async {
  final cli = Cli(name: 'keybox', description: 'Key BOX Scraper & Downloader')
    ..choice('format', ['mp3', 'flac', 'all'], abbr: 'f', defaultTo: 'all', description: 'Music format')
    ..number('concurrency', abbr: 'j', defaultTo: 4, description: 'Concurrent download workers')
    ..flag('compress', abbr: 'c', description: 'Compress directory after download')
    ..action((ctx) => Http.session(() => run(ctx), timeout: 60.s));

  await cli.run(rawArgs);
}

Future<void> run(CliContext ctx) async {
  final selectedFormat = ctx.option('format');
  final formats = selectedFormat == 'all' ? const ['mp3', 'flac'] : [selectedFormat];
  final concurrency = ctx.number('concurrency');
  final shouldCompress = ctx.flag('compress');
  final stage = Logger.stages(shouldCompress ? 3 : 2);

  final base = baseName.path;
  final baseUri = keyBase.url;
  final artwork = <Uri, Path>{};
  final discNames = <int, Path>{};
  final tracks = <int, Map<int, Path>>{};

  // Stage 1: Official metadata & images
  stage('Scraping official album metadata and artworks');
  await Console.spin('Parsing official website...', () async {
    final doc = await (baseUri / 'key_box.html').html();
    for (final li in doc.$('.key_cd_track_box ul li')) {
      final title = li.$('.track_disc_title').text.filename;
      final d = int.parse(title.match(RegExp(r'DISC\.(\d+)'), 1)!);
      discNames[d] = title;
      tracks[d] = {
        for (final line in li.$('.track_disc_text_style1').lines)
          if (RegExp(r'^(\d+)\.(.*)$').firstMatch(line) case final m?)
            int.parse(m[1]!): (d == 22 && m[1] == '13') ? '小さなてのひら'.filename : m[2]!.filename,
      };
    }

    for (final e in doc.$('.key_cd_artworks_box')) {
      final href = e.$('a').attr('href')!;
      if (e.text.match(RegExp(r'DISC(\d+)'), 1) case final dStr?) {
        artwork[baseUri / href] = base / discNames[int.parse(dStr)]! / href.path.name;
      } else if (e.text.contains('ALL')) {
        artwork[baseUri / href] = base / 'Others/KeyBOX' / href.path.name;
      }
    }

    artwork.addAll({
      baseUri / 'common/album_jacket/keybox_image.png': base / 'Others/KeyBOX/keybox_image.png',
      for (final n in [
        '20th_box_image.jpg',
        'key_box_main_image.png',
        'sp_key_box_main_image.png',
        'key_box_bg.jpg',
        'key_box_onsale_title3.jpg',
        'sp_20th_banner_keybox.png',
      ])
        baseUri / 'common/image/$n': base / 'Others/KeyBOX' / n,
      'https://jetta.vgmtreasurechest.com/soundtracks/key-box-for-two-decades-2019/00%20Contents.jpg'.url:
          base / 'Others/KeyBOX/00_Contents.jpg',
      'https://jetta.vgmtreasurechest.com/soundtracks/key-box-for-two-decades-2019/01%20Box%20sample.png'.url:
          base / 'Others/KeyBOX/01_Box_sample.png',
      for (final n in [
        '20th_main_image.jpg',
        '20th_main_bg.jpg',
        '20th_top_main_banner_1.png',
        '20th_menu_logo.png',
        'sp_20th_top_title.png',
        'sp_20th_main_image_1.jpg',
        'sp_20th_main_image_2.jpg',
        'sp_20th_main_image_3.jpg',
      ])
        baseUri / 'common/image/$n': base / 'Others/Key 20th Anniversary' / n,
      for (final n in [
        'Stamp Rally/key20th_stamp_poster_1.jpg',
        'Stamp Rally/key20th_stamp_poster_1_a.jpg',
        'movie_image_0712.jpg',
        'history_image_50.jpg',
        'topics_image_20191217_2.jpg',
        for (var i = 1; i <= 8; i++) 'General Election/key_election_$i.jpg',
        for (final name in [
          'kai',
          'tanaka',
          'minami',
          'na-ga',
          'suzukikeiko',
          'sakurai',
          'kohara',
          'orito',
          'suzuki',
          'yurika',
        ])
          'Live Streams/profile_$name.jpg',
      ])
        baseUri / 'common/image/${n.path.name}': base / 'Others/Events & Topics' / n,
    });

    final msgDoc = await (baseUri / 'message.html').html();
    const categories = ['Anime Staff', 'Voice Cast', 'Guest Tributes', 'Key Staff & Creators'];
    for (final (i, box) in msgDoc.$('.message_white_box').take(4).indexed) {
      for (final (n, a) in box.$('a[href*="message_"]').indexed) {
        final href = a.attr('href')!;
        final tag = href.contains('wfs')
            ? 'WFS_'
            : href.contains('cygames')
            ? 'Cygames_'
            : '';
        final pfx = '${n + 1}'.padLeft(2, '0');
        final name = (a.attr('title') ?? a.text.replaceAll('[New Message]', '')).filename;
        artwork[baseUri / href] = base / 'Others/Messages & Tributes' / categories[i] / '$tag${pfx}_$name.jpg';
      }
    }

    final topicsDoc = await (baseUri / 'topics.html').html();
    for (final img in topicsDoc.$('.topics_box img')) {
      final src = img.attr('src')!;
      artwork[baseUri / src] = base / 'Others/Events & Topics' / src.path.name;
    }
  });
  Logger.ok('Found ${discNames.length} discs and ${artwork.length} artwork/document assets.');

  // Stage 2: Track links and downloads, merged — tracks resolve while artwork transfers.
  stage('Resolving tracks and downloading assets (concurrency: $concurrency)');
  final songs = khinsider.url
      .scrape<Asset>()
      .onResponse((ctx) {
        for (final tr in ctx.response.html.$('#songlist tr')) {
          final tds = tr.$('td');
          if (tds.length < 4) continue;
          final href = tds[3].$('a').attr('href')!;
          final d = int.parse(href.match(RegExp(r'/(\d+)-'), 1) ?? tds[1].text.replaceAll(RegExp(r'\D'), ''));
          final t = int.parse(href.match(RegExp(r'-(\d+)\.'), 1) ?? tds[2].text.replaceAll(RegExp(r'\D'), ''));
          final title = tracks[d]?[t] ?? tds[3].text.filename;
          final missing = {for (final ext in formats) ext: base / discNames[d]! / ext / '$t. $title.$ext'}
            ..removeWhere((_, path) => path.existsSync());
          if (missing.isEmpty) continue;

          ctx.follow(
            href,
            onResponse: (song) {
              final page = song.response.html;
              for (final MapEntry(key: ext, value: path) in missing.entries) {
                song.emit((url: song.resolve(page.$('a[href*=".$ext"]').attr('href')!), path: path));
              }
            },
          );
        }
      })
      .onError((ctx) => Logger.warn('${ctx.failure}'))
      .rights;

  final last = await [Stream.fromIterable(artwork.pairs), songs]
      .merge()
      .downloadAll(concurrency: concurrency, cancelToken: ctx.cancel)
      .show(slots: concurrency, message: 'Downloading', done: 'All assets downloaded.');

  // Stage 3: Archive (if requested)
  if (shouldCompress) {
    stage('Creating zip archive');
    await Console.spin('Compressing $baseName.zip...', () => base.zipTo('$baseName.zip'));
  }

  Console.table(
    headers: ['Property', 'Value'],
    rows: [
      ['Format', selectedFormat],
      ['Assets', last?.total ?? 0],
      ['Downloaded', last?.written ?? 0],
      ['Discs', discNames.length],
      ['Compression', shouldCompress ? 'Enabled ($baseName.zip)' : 'Disabled'],
    ],
  );

  Logger.ok('Completed successfully.');
}
