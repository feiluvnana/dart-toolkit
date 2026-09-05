import 'package:dart_toolkit/dart_toolkit.dart';

void main(List<String> rawArgs) async {
  // 1. System & CLI Parsing (system.cli.* or cli.*)
  system.cli.parse(rawArgs);
  final concurrency = system.cli.get('concurrency', 4);
  final force = system.cli.has('force', 'f');

  // 2. Process listening & Stopwatch (system.clock())
  system.listen();
  final clock = system.clock();

  util.console.logger.step(1, 4, 'Starting automation workflow...');

  // 3. Web Crawling & Scraping (net.crawl.* or crawl.*)
  util.console.logger.step(2, 4, 'Crawling news headlines with crawl engine...');
  final titles = await net.crawl<String>('https://news.ycombinator.com')
      .concurrent(concurrency)
      .collect<String>((res) {
        for (final title in res.$('.titleline > a').texts) {
          res.emit(title);
        }
      });
  util.console.logger.ok('Engine collected ${titles.length} news items.');

  // 4. Concurrency pool processing (concurrent.run.* or parallel.run.*)
  util.console.logger.step(3, 4, 'Processing items concurrently...');
  final bar = util.console.bar(titles.take(10).length, 'Processing');
  final processed = await concurrent.run(titles.take(10), (title) async {
    await util.time.wait(50);
    bar.tick(1, title);
    return title.toUpperCase();
  }, size: concurrency);
  bar.done();

  // 5. Input/Output: Atomic File System & Paths (io.* or fs.*)
  util.console.logger.step(4, 4, 'Saving output atomically...');
  final outFile = io.join('output', 'summary.txt');
  if (force || !io.has(outFile)) {
    await io.write(outFile, processed.join('\n'));
    util.console.logger.ok('Saved output to $outFile');
  }

  // 6. Visual Table Output (util.console.writer.*)
  util.console.writer.table(
    ['Metric', 'Value'],
    [
      ['Total Crawled', titles.length],
      ['Total Processed', processed.length],
      ['Output Destination', outFile],
      ['Elapsed Time', io.time(clock.elapsed)],
    ],
  );

  util.console.logger.ok('Automation finished successfully!');
  system.unlisten();
}
