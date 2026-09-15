import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

const khinsiderUrl = 'https://downloads.khinsider.com/game-soundtracks/album/key-box-for-two-decades-2019';
const keyBaseUrl = 'https://key.visualarts.gr.jp/key20th/';
const baseFolderName = 'Key BOX -for two decades- (2019)';

void main(List<String> rawArgs) async {
  final cli = Cli(name: 'keybox', description: 'Key BOX -for two decades- (2019) Scraper & Downloader');

  cli
    ..option('concurrency', abbreviated: true, numeric: true, defaultTo: '4', description: 'Concurrent downloads')
    ..option('force-compress', abbreviated: true, flag: true, description: 'Force zip compression')
    ..option('no-compress', abbreviated: true, flag: true, description: 'Skip zip packaging')
    ..action((ctx) async {
      final concurrency = ctx.number('concurrency', defaultTo: 4)!;
      final skipCompress = ctx.flag('no-compress');

      final stopwatch = Stopwatch()..start();
      final client = http.Client();
      final base = Path(baseFolderName);
      final baseUri = keyBaseUrl.url;
      var newDownloads = 0;

      final discNames = <int, String>{};
      final tracks = <int, Map<int, String>>{};

      try {
        // Step 1: Official KeyBOX metadata & disc artworks
        Logger.step(1, 6, 'Fetching official KeyBOX metadata & disc artworks...');
        final keyBoxPage = await client.html(baseUri / 'key_box.html');

        for (final li in keyBoxPage.$('.key_cd_track_box ul li').elements) {
          final title = li.query.$('.track_disc_title').text.path.sanitized();
          if (title.match(r'DISC\.(\d+)', 1)?.int case final int d) {
            discNames[d] = title;
            tracks[d] = {
              for (final line in li.query.$('.track_disc_text_style1').lines)
                if (RegExp(r'^(\d+)\.(.*)$').firstMatch(line) case final m?)
                  if (m.group(1)?.int case final int num) num: (d == 22 && num == 13) ? '小さなてのひら' : m.group(2)!.trim(),
            };
          }
        }
        Logger.ok('Loaded ${discNames.length} discs metadata.');

        final artworks = <Path, Uri>{
          for (final e in keyBoxPage.$('.key_cd_artworks_box').elements)
            if (e.text.digits.int case final int d)
              if (discNames[d] case final name?)
                if (e.query.$('a').attr('href') case final href?) base / name / p.basename(href): baseUri / href,
        };
        newDownloads += await artworks.downloadAll(client: client, concurrency: concurrency);
        Logger.ok('Disc artworks checked.');

        // Step 2: KeyBOX visuals & anniversary assets
        Logger.step(2, 6, 'Checking KeyBOX visuals & anniversary assets...');
        final visuals = <Path, Uri>{
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
          ])
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
        };
        newDownloads += await visuals.downloadAll(client: client, concurrency: concurrency);
        Logger.ok('Visual assets checked.');

        // Step 3: Audio tracks
        Logger.step(3, 6, 'Fetching khinsider track list & audio...');
        final albumPage = await client.html(khinsiderUrl.url);
        final pending = <({Uri url, Path Function(String ext) target, String label})>[];

        for (final tr in albumPage.$('#songlist tr').elements) {
          final tds = tr.query.$('td');
          if (tds.length < 4) continue;
          final href = tds.at(3).$('a').attr('href');
          if (href == null) continue;

          final d = href.match(r'\/(\d+)-', 1)?.int ?? tds.at(1).text.digits.int ?? 1;
          final t = href.match(r'-(\d+)\.', 1)?.int ?? tds.at(2).text.digits.int ?? 1;
          final disc = discNames[d] ?? 'DISC $d';
          final title = (tracks[d]?[t] ?? tds.at(3).text).path.sanitized();

          Path target(String ext) => base / disc / ext / '$t. $title.$ext';
          if (!await target('mp3').exist() || !await target('flac').exist()) {
            pending.add((url: khinsiderUrl.url / href, target: target, label: '$disc #$t'));
          }
        }

        if (pending.isEmpty) {
          Logger.ok('All audio tracks are already downloaded.');
        } else {
          Logger.info('Downloading ${pending.length} pending tracks (concurrency: $concurrency)...');
          final progress = Console.progress(pending.length, message: 'Audio Tracks');

          await pending.parallelize((pTrack) async {
            try {
              final songPage = await client.html(pTrack.url);
              for (final ext in const ['mp3', 'flac']) {
                if (songPage.$('a[href*=".$ext"]').attr('href') case final href?) {
                  if (await pTrack.target(ext).download(pTrack.url / href, client: client)) {
                    newDownloads++;
                  }
                }
              }
            } catch (err) {
              Logger.error('Failed fetching track ${pTrack.url}: $err');
            }
            progress.tick(1, pTrack.label);
          }, concurrency: concurrency);

          progress.done('All audio tracks processed.');
        }

        // Step 4: Tribute messages
        Logger.step(4, 6, 'Checking creator tribute messages...');
        final msgPage = await client.html(baseUri / 'message.html');
        const categories = ['Anime Staff', 'Voice Cast', 'Guest Tributes', 'Key Staff & Creators'];
        final tributes = <Path, Uri>{};

        for (final (i, box) in msgPage.$('.message_white_box').elements.indexed) {
          if (i >= categories.length) break;
          for (final (n, a) in box.query.$('a[href*="message_"]').elements.indexed) {
            if (a.attributes['href'] case final href?) {
              final tag = href.contains('wfs')
                  ? 'WFS_'
                  : href.contains('cygames')
                  ? 'Cygames_'
                  : '';
              final pfx = '${n + 1}'.padLeft(2, '0');
              final name = (a.attributes['title'] ?? a.text.replaceAll('[New Message]', '')).path.sanitized();
              tributes[base / 'Others/Messages & Tributes/${categories[i]}/$tag${pfx}_$name.jpg'] = baseUri / href;
            }
          }
        }
        newDownloads += await tributes.downloadAll(client: client, concurrency: concurrency);
        Logger.ok('Tribute messages checked.');

        // Step 5: Topics visuals
        Logger.step(5, 6, 'Checking topics event visuals...');
        final topicsPage = await client.html(baseUri / 'topics.html');
        final topics = <Path, Uri>{
          for (final img in topicsPage.$('.topics_box img').elements)
            if (img.attributes['src'] case final src?) base / 'Others/Events & Topics' / p.basename(src): baseUri / src,
        };
        newDownloads += await topics.downloadAll(client: client, concurrency: concurrency);
        Logger.ok('Topics visuals checked.');
      } finally {
        client.close();
      }

      // Step 6: Compress KeyBOX archive
      Logger.step(6, 6, 'Compressing KeyBOX archive...');
      final zipPath = '$baseFolderName.zip';
      var archiveStatus = 'Skipped';
      if (!skipCompress) {
        if (await base.exist()) {
          await base.zip(zipPath);
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
          ['New Downloads', '$newDownloads', newDownloads > 0 ? 'Downloaded' : 'Up to date'],
          ['Archive', zipPath, archiveStatus],
          ['Elapsed Time', stopwatch.elapsed.humanize(), 'Completed'],
        ],
      );
      stdout.writeln();
    });

  await cli.run(rawArgs);
}
