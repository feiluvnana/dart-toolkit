import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';

const khinsiderUrl = 'https://downloads.khinsider.com/game-soundtracks/album/key-box-for-two-decades-2019';
const keyBaseUrl = 'https://key.visualarts.gr.jp/key20th/';
const baseFolderName = 'Key BOX -for two decades- (2019)';

void main(List<String> rawArgs) async {
  final cli = Cli(name: 'keybox', description: 'Key BOX -for two decades- (2019) Scraper & Downloader');

  onExit(() {
    Logger.warn('KeyBOX download operation interrupted by user.');
  });

  cli
    ..option('concurrency', abbreviated: true, numeric: true, defaultTo: '4', description: 'Concurrent downloads')
    ..option('no-compress', abbreviated: true, flag: true, description: 'Skip zip packaging')
    ..action((ctx) async {
      final concurrency = ctx.number('concurrency', defaultTo: 4)!;
      final skipCompress = ctx.flag('no-compress');

      final stopwatch = Stopwatch()..start();
      final base = baseFolderName.path;
      final baseUri = keyBaseUrl.url;
      final downloads = <Path, Uri>{};
      final discNames = <int, String>{};
      final tracks = <int, Map<int, String>>{};

      // Step 1: Scrape official KeyBOX metadata & visuals
      Logger.step(1, 4, 'Scraping official KeyBOX metadata and site visuals...');
      final keyBoxDoc = await (baseUri / 'key_box.html').html();

      for (final li in keyBoxDoc.$('.key_cd_track_box ul li')) {
        final title = (li.$('.track_disc_title').firstOrNull?.text ?? '').path.sanitized();
        if (int.tryParse(title.match(r'DISC\.(\d+)', 1) ?? '') case final int d) {
          discNames[d] = title;
          tracks[d] = {
            for (final line in li.$('.track_disc_text_style1').firstOrNull?.lines ?? const <String>[])
              if (RegExp(r'^(\d+)\.(.*)$').firstMatch(line) case final m?)
                if (int.tryParse(m.group(1) ?? '') case final int num)
                  num: (d == 22 && num == 13) ? '小さなてのひら' : m.group(2)!.trim(),
          };
        }
      }

      for (final e in keyBoxDoc.$('.key_cd_artworks_box')) {
        if (int.tryParse(e.text.replaceAll(RegExp(r'\D'), '')) case final int d) {
          if (discNames[d] case final name?) {
            if (e.$('a').firstOrNull?.attr('href') case final href?) {
              downloads[base / name / href.path.name] = baseUri / href;
            }
          }
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
        base / 'Others/Events & Topics/Stamp Rally/key20th_stamp_poster_1.jpg':
            baseUri / 'common/image/key20th_stamp_poster_1.jpg',
        base / 'Others/Events & Topics/Stamp Rally/key20th_stamp_poster_1_a.jpg':
            baseUri / 'common/image/key20th_stamp_poster_1_a.jpg',
        for (final n in ['movie_image_0712.jpg', 'history_image_50.jpg', 'topics_image_20191217_2.jpg'])
          base / 'Others/Events & Topics' / n: baseUri / 'common/image/$n',
        for (var i = 1; i <= 8; i++)
          base / 'Others/Events & Topics/General Election/key_election_$i.jpg':
              baseUri / 'common/image/key_election_$i.jpg',
        for (final n in [
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
          base / 'Others/Events & Topics/Live Streams/profile_$n.jpg': baseUri / 'common/image/profile_$n.jpg',
      });

      final msgDoc = await (baseUri / 'message.html').html();
      const categories = ['Anime Staff', 'Voice Cast', 'Guest Tributes', 'Key Staff & Creators'];
      for (final (i, box) in msgDoc.$('.message_white_box').indexed) {
        if (i >= categories.length) break;
        for (final (n, a) in box.$('a[href*="message_"]').indexed) {
          if (a.attr('href') case final href?) {
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
      }

      final topicsDoc = await (baseUri / 'topics.html').html();
      for (final img in topicsDoc.$('.topics_box img')) {
        if (img.attr('src') case final src?) {
          downloads[base / 'Others/Events & Topics' / src.path.name] = baseUri / src;
        }
      }
      Logger.ok('Scraped ${discNames.length} discs metadata and ${downloads.length} visual asset links.');

      // Step 2: Scrape KHInsider album & audio download links with scraping pipeline
      Logger.step(2, 4, 'Scraping khinsider track list and resolving audio downloads...');
      final audioStream = khinsiderUrl.url.scrape<({Path path, Uri url})>((res) async {
        for (final tr in res.$('#songlist tr')) {
          final tds = tr.$('td');
          if (tds.length < 4) continue;
          final href = tds[3].$('a').firstOrNull?.attr('href');
          if (href == null) continue;

          final d =
              int.tryParse(href.match(r'\/(\d+)-', 1) ?? '') ??
              int.tryParse(tds[1].text.replaceAll(RegExp(r'\D'), '')) ??
              1;
          final t =
              int.tryParse(href.match(r'-(\d+)\.', 1) ?? '') ??
              int.tryParse(tds[2].text.replaceAll(RegExp(r'\D'), '')) ??
              1;
          final disc = discNames[d] ?? 'DISC $d';
          final title = (tracks[d]?[t] ?? tds[3].text).path.sanitized();

          final mp3Path = base / disc / 'mp3' / '$t. $title.mp3';
          final flacPath = base / disc / 'flac' / '$t. $title.flac';
          final needMp3 = !await mp3Path.exist();
          final needFlac = !await flacPath.exist();

          if (needMp3 || needFlac) {
            res.follow(
              href,
              callback: (songRes) {
                for (final ext in const ['mp3', 'flac']) {
                  if (songRes.$('a[href*=".$ext"]').firstOrNull?.attr('href') case final dlHref?) {
                    final target = base / disc / ext / '$t. $title.$ext';
                    songRes.emit((path: target, url: (songRes.url ?? khinsiderUrl.url).resolve(dlHref)));
                  }
                }
              },
            );
          }
        }
      }, concurrency: concurrency);

      await for (final item in audioStream) {
        downloads[item.path] = item.url;
      }
      Logger.ok('Total queue: ${downloads.length} assets (visuals + audio).');

      // Step 3: Streamed concurrent download
      Logger.step(3, 4, 'Downloading all pending assets (concurrency: $concurrency)...');
      final progress = Console.progress(downloads.length, message: 'Assets');
      var newDownloads = 0;

      await for (final status in downloads.downloadAll(concurrency: concurrency)) {
        if (status.current.isDone) {
          progress.tick(1, status.current.path.name);
        }
        newDownloads = status.newDownloads;
      }
      progress.done('All assets checked and synchronized.');

      // Step 4: Compress KeyBOX archive
      Logger.step(4, 4, 'Packaging KeyBOX archive...');
      final zipPath = '$baseFolderName.zip';
      var archiveStatus = 'Skipped';
      if (!skipCompress) {
        if (await base.exist()) {
          await Console.spin('Compressing KeyBOX archive into $zipPath...', () async {
            await base.zip(zipPath);
          });
          archiveStatus = zipPath;
        } else {
          archiveStatus = 'Base dir not found';
        }
      }

      // Final Summary
      stopwatch.stop();
      stdout.writeln();
      Console.rule('Execution Summary');
      Console.table(
        headers: ['Task', 'Result', 'Details'],
        rows: [
          ['Discs Scraped', '${discNames.length}', 'Official KeyBOX discs'],
          ['Total Assets', '${downloads.length}', 'Visuals + Audio tracks'],
          ['New Downloads', '$newDownloads', newDownloads > 0 ? 'Downloaded' : 'Up to date'],
          ['Archive', zipPath, archiveStatus],
          ['Elapsed Time', stopwatch.elapsed.humanize(), 'Completed'],
        ],
      );
      stdout.writeln();
    });

  await cli.run(rawArgs);
}
