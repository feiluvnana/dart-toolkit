import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:http/http.dart' as http;

void main(List<String> args) async {
  final cli = Cli(name: 'demo', description: 'Sample CLI using dart-toolkit');

  cli.command('scrape', description: 'Scrape URLs concurrently')
    ..option('concurrency', abbreviated: true, numeric: true, defaultTo: '2')
    ..option('out', abbreviated: true, defaultTo: 'output')
    ..option('verbose', flag: true)
    ..action((ctx) async {
      final concurrency = ctx.number('concurrency')!;
      final isVerbose = ctx.flag('verbose');
      final outDir = Path(ctx.option('out')!).dir;

      if (isVerbose) {
        print('Starting parallel scrape (concurrency: $concurrency)...'.cyan);
      }

      final urls = ['https://example.com', 'https://httpbin.org/html'];

      final results = await urls.parallelize((url) async {
        final res = await http.get(Uri.parse(url));
        return res.html().$('h1').text;
      }, concurrency: concurrency);

      final titles = [
        for (final r in results)
          if (r case Right(:final value)) value,
      ];

      await outDir.create(recursive: true);
      final outFile = (Path(outDir.path) / 'titles.txt').file;
      await outFile.writeAsString(titles.join('\n'));

      print('Wrote ${titles.length} titles to ${outFile.path}'.green.bold);
    });

  await cli.run(args);
}
