import 'package:dart_toolkit/dart_toolkit.dart';

const keyBase = 'https://key.visualarts.gr.jp/key20th/';
const khinsider = 'https://downloads.khinsider.com/game-soundtracks/album/key-box-for-two-decades-2019';
const baseName = 'Key BOX -for two decades- (2019)';

void main(List<String> rawArgs) async {
  final cli = Cli(name: 'keybox', description: 'Key BOX Scraper & Downloader')
    ..choice('format', ['mp3', 'flac', 'all'], abbr: 'f', defaultTo: 'all', description: 'Music format')
    ..option('concurrency', abbr: 'j', defaultTo: '4', description: 'Concurrent download workers')
    ..flag('compress', abbr: 'c', description: 'Compress directory after download')
    ..action((ctx) async {
      onExit(() => Logger.warn('Interrupted.'));

      final selectedFormat = ctx.option('format', defaultTo: 'all')!;
      final formats = selectedFormat == 'all' ? const ['mp3', 'flac'] : [selectedFormat];
      final concurrency = ctx.number('concurrency', defaultTo: 4)!;
      final shouldCompress = ctx.flag('compress');
      final totalStages = shouldCompress ? 4 : 3;

      final base = baseName.path;
      final baseUri = keyBase.url;
      final downloads = <Path, Uri>{};
      final discNames = <int, String>{};
      final tracks = <int, Map<int, String>>{};

      // Stage 1: Official metadata & images
      Logger.step(1, totalStages, 'Scraping official album metadata and artworks');
      await Console.spin('Parsing official website...', () async {
        final doc = await (baseUri / 'key_box.html').isolateHtml((d) => d);
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
          final href = e.$('a').first.attr('href')!;
          if (e.text.match(r'DISC(\d+)', 1) case final dStr?) {
            downloads[base / discNames[int.parse(dStr)]! / href.path.name] = baseUri / href;
          } else if (e.text.contains('ALL')) {
            downloads[base / 'Others/KeyBOX' / href.path.name] = baseUri / href;
          }
        }

        downloads.addAll({
          base / 'Others/KeyBOX/keybox_image.png': baseUri / 'common/album_jacket/keybox_image.png',
          for (final n in [
            '20th_box_image.jpg',
            'key_box_main_image.png',
            'sp_key_box_main_image.png',
            'key_box_bg.jpg',
            'key_box_onsale_title3.jpg',
            'sp_20th_banner_keybox.png',
          ])
            base / 'Others/KeyBOX' / n: baseUri / 'common/image/$n',
          base / 'Others/KeyBOX/00_Contents.jpg':
              'https://jetta.vgmtreasurechest.com/soundtracks/key-box-for-two-decades-2019/00%20Contents.jpg'.url,
          base / 'Others/KeyBOX/01_Box_sample.png':
              'https://jetta.vgmtreasurechest.com/soundtracks/key-box-for-two-decades-2019/01%20Box%20sample.png'.url,
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
            base / 'Others/Key 20th Anniversary' / n: baseUri / 'common/image/$n',
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
            base / 'Others/Events & Topics' / n: baseUri / 'common/image/${n.path.name}',
        });

        final msgDoc = await (baseUri / 'message.html').isolateHtml((d) => d);
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
            final name = (a.attr('title') ?? a.text.replaceAll('[New Message]', '')).path.sanitized();
            downloads[base / 'Others/Messages & Tributes/${categories[i]}/$tag${pfx}_$name.jpg'] = baseUri / href;
          }
        }

        final topicsDoc = await (baseUri / 'topics.html').isolateHtml((d) => d);
        for (final img in topicsDoc.$('.topics_box img')) {
          final src = img.attr('src')!;
          downloads[base / 'Others/Events & Topics' / src.path.name] = baseUri / src;
        }
      });
      Logger.ok('Found ${discNames.length} discs and ${downloads.length} artwork/document assets.');

      // Stage 2: Audio tracks scraping
      Logger.step(2, totalStages, 'Scraping audio tracks and download links');
      var audioTracksCount = 0;
      await Console.spin('Resolving track links from repository...', () async {
        final audioStream = khinsider.url.scrape<({Path path, Uri url})>((res) async {
          for (final tr in res.$('#songlist tr')) {
            final tds = tr.$('td');
            if (tds.length < 4) continue;
            final href = tds[3].$('a').first.attr('href')!;
            final d = int.parse(href.match(r'\/(\d+)-', 1) ?? tds[1].text.replaceAll(RegExp(r'\D'), ''));
            final t = int.parse(href.match(r'-(\d+)\.', 1) ?? tds[2].text.replaceAll(RegExp(r'\D'), ''));
            final disc = discNames[d]!;
            final title = (tracks[d]?[t] ?? tds[3].text).path.sanitized();

            for (final ext in formats) {
              final target = base / disc / ext / '$t. $title.$ext';
              if (!target.existSync()) {
                res.follow(
                  href,
                  callback: (songRes) {
                    final dlHref = songRes.$('a[href*=".$ext"]').first.attr('href')!;
                    return (path: target, url: (songRes.url ?? khinsider.url).resolve(dlHref));
                  },
                );
              }
            }
          }
        }, concurrency: concurrency);

        await for (final item in audioStream) {
          downloads[item.path] = item.url;
          audioTracksCount++;
        }
      });
      Logger.ok('Enqueued $audioTracksCount audio track downloads ($selectedFormat).');

      // Stage 3: Download batch
      Logger.step(3, totalStages, 'Downloading assets (${downloads.length} files, concurrency: $concurrency)');
      final progress = Console.multiProgress(downloads.length, slots: concurrency, message: 'Downloading');
      await for (final status in downloads.downloadAll(concurrency: concurrency)) {
        progress.update(status);
      }
      progress.done('All assets downloaded.');

      // Stage 4: Archive (if requested)
      if (shouldCompress) {
        Logger.step(4, totalStages, 'Creating zip archive');
        await Console.spin('Compressing $baseName.zip...', () => base.zip('$baseName.zip'));
      }

      // Summary Table
      Console.table(
        headers: ['Property', 'Value'],
        rows: [
          ['Format', selectedFormat],
          ['Total Assets', '${downloads.length}'],
          ['Discs', '${discNames.length}'],
          ['Compression', shouldCompress ? 'Enabled ($baseName.zip)' : 'Disabled'],
        ],
      );

      Logger.ok('Completed successfully.');
      onExit(null);
    });

  await cli.run(rawArgs);
}
