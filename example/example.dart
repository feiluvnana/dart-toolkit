import 'package:toolkit/toolkit.dart';

void main(List<String> rawArgs) async {
  // 1. CLI Parsing
  cli.parse(rawArgs);
  final concurrency = cli.get('concurrency', 4);
  final force = cli.has('force', 'f');

  // 2. Process listening & Stopwatch
  sys.listen();
  final clock = sys.clock();

  console.step(1, 4, 'Starting automation workflow...');

  // 3. Web Scraping
  final res = await crawl.get('https://news.ycombinator.com');
  final titles = res.$('.titleline > a').texts;
  console.ok('Found ${titles.length} news items.');

  // 4. Concurrently processing items
  final bar = console.bar(titles.take(10).length, 'Processing');
  final processed = await parallel.run(titles.take(10), (title) async {
    await Future.delayed(const Duration(milliseconds: 50));
    bar.tick(1, title);
    return title.toUpperCase();
  }, size: concurrency);
  bar.done();

  // 5. Atomic File System & Paths
  final outFile = fs.join('output', 'summary.txt');
  if (force || !fs.has(outFile)) {
    await fs.write(outFile, processed.join('\n'));
    console.ok('Saved output to $outFile');
  }

  // 6. Visual Table Output
  console.writer.table(['Metric', 'Value'], [
    ['Total Processed', processed.length],
    ['Output Destination', outFile],
    ['Elapsed Time', fs.time(clock.elapsed)],
  ]);

  console.ok('Automation finished successfully!');
}
