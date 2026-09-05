import 'package:dart_toolkit/dart_toolkit.dart';

void main(List<String> rawArgs) async {
  // 1. CLI Parsing
  cli.parse(rawArgs);
  final concurrency = cli.get('concurrency', 4);
  final force = cli.has('force', 'f');

  // 2. Process listening & Stopwatch
  sys.listen();
  final clock = sys.clock();

  console.logger.step(1, 4, 'Starting automation workflow...');

  // 3. Web Crawling & Scraping with Engine
  console.logger.step(2, 4, 'Crawling news headlines with crawl engine...');
  final titles = await crawl.collect<String>(
    'https://news.ycombinator.com',
    (res) {
      for (final title in res.$('.titleline > a').texts) {
        res.emit(title);
      }
    },
    concurrency: concurrency,
  );
  console.logger.ok('Engine collected ${titles.length} news items.');

  // 4. Concurrently processing items
  console.logger.step(3, 4, 'Processing items concurrently...');
  final bar = console.bar(titles.take(10).length, 'Processing');
  final processed = await parallel.run(titles.take(10), (title) async {
    await Future.delayed(const Duration(milliseconds: 50));
    bar.tick(1, title);
    return title.toUpperCase();
  }, size: concurrency);
  bar.done();

  // 5. Atomic File System & Paths
  console.logger.step(4, 4, 'Saving output atomically...');
  final outFile = fs.join('output', 'summary.txt');
  if (force || !fs.has(outFile)) {
    await fs.write(outFile, processed.join('\n'));
    console.logger.ok('Saved output to $outFile');
  }

  // 6. Visual Table Output
  console.writer.table(['Metric', 'Value'], [
    ['Total Crawled', titles.length],
    ['Total Processed', processed.length],
    ['Output Destination', outFile],
    ['Elapsed Time', fs.time(clock.elapsed)],
  ]);

  console.logger.ok('Automation finished successfully!');
}
