import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/image.dart';
import 'package:dart_toolkit/pool.dart';
import 'package:dart_toolkit/tui.dart';

import 'site.dart';

enum JobStatus {
  queued('…'),
  active('⇣'),
  paused('⏸'),
  done('✓'),
  failed('✗');

  const JobStatus(this.icon);
  final String icon;
}

final class Job {
  Job(this.series, this.chapter);
  final Hit series;
  final Chapter chapter;
  var status = JobStatus.queued;
  var halt = false; // stop after the pages already downloading
  var done = 0; // pages finished
  int? total;
  var missing = <int>[]; // pages still to fetch; empty means all of them
  String? error;
  String get dir =>
      Fs.scriptDir().dir('downloads').dir(Fs.sanitize(series.title)).dir(Fs.sanitize(chapter.title)).path();

  // Written once every page is on disk, so a half-done chapter gets resumed.
  File get marker => Fs.dir(dir).file('.done');
}

// Doesn't throw: the result ends up in job.status, job.missing and job.error.
Future<void> fetchChapter(Job job) async {
  job.status = JobStatus.active;
  job.error = null;
  job.done = 0;
  job.total = null;
  try {
    final images = await chapterImages(job.chapter.postId);
    if (images.isEmpty) throw const ContentException('no images found');
    final todo = job.missing.isEmpty ? List.generate(images.length, (i) => i) : job.missing;
    job.total = images.length;
    job.done = images.length - todo.length;

    final errors = await Pool.map(todo, (i) async {
      if (job.halt) return halted;
      final url = images[i];
      final error = url == null ? 'p${i + 1} withheld by the site' : await fetchPage(job, i, url);
      job.done++;
      return error;
    });

    job.missing = [];
    for (var k = 0; k < todo.length; k++) {
      if (errors[k] == null) continue;
      job.missing.add(todo[k]);
      if (errors[k] != halted) job.error ??= errors[k];
    }
    if (job.missing.isEmpty) {
      await job.marker.write('${images.length}');
      job.status = JobStatus.done;
    } else {
      job.status = job.halt ? JobStatus.paused : JobStatus.failed;
    }
  } catch (e) {
    job.status = job.halt ? JobStatus.paused : JobStatus.failed;
    job.error = '$e';
  }
}

const halted = 'halted';

// Returns null when the page was saved, otherwise why not.
Future<String?> fetchPage(Job job, int i, String url) async {
  final n = i + 1;
  try {
    final img = await site.get(url);
    if (!img.ok()) {
      await img.close();
      return 'HTTP ${img.status()} p$n';
    }
    final data = await img.bytes();
    if (data.length < 1024) return 'empty reply p$n';
    // No extension and no content type, so look at the bytes.
    await (Reader.of(data) > Fs.dir(job.dir).file('${'$n'.padLeft(3, '0')}.${(Image.sniff(data) ?? .jpg).name}'));
    return null;
  } on Exception catch (e) {
    return 'p$n: $e';
  }
}

// Downloads one chapter at a time, in the order they were added, across all
// series. Pausing stops the current chapter after the pages in flight; it
// resumes with just the missing pages.
final class Queue {
  final jobs = <String, Job>{}; // by chapter url
  final onDisk = <String>{}; // chapter urls
  final lines = <String>[];
  final scroll = Scroll();
  var paused = false, _running = false, _stopped = false;

  Iterable<Job> where(JobStatus s) => jobs.values.where((j) => j.status == s);

  String icon(Chapter ch) => jobs[ch.url]?.status.icon ?? (onDisk.contains(ch.url) ? '✓' : ' ');

  // Failed or paused chapters go back in the queue for their missing pages.
  void add(Hit series, Iterable<Chapter> chapters) {
    for (final ch in chapters) {
      final job = jobs.putIfAbsent(ch.url, () => Job(series, ch));
      if (job.status case JobStatus.failed || JobStatus.paused) job.status = JobStatus.queued;
    }
    _pump();
  }

  void remove(Chapter ch) => jobs.remove(ch.url)?.halt = true;

  void pause() {
    paused = !paused;
    for (final j in where(JobStatus.active)) {
      j.halt = paused;
    }
    if (paused) return;
    for (final j in where(JobStatus.paused)) {
      j.status = JobStatus.queued;
    }
    _pump();
  }

  // Cancels everything. The unfinished chapter has no .done file, so the next
  // run picks it up again.
  void stop() {
    _stopped = true;
    for (final j in jobs.values) {
      j.halt = true;
    }
    for (final c in [site, wpApi, anilist]) {
      c.close();
    }
  }

  Future<void> _pump() async {
    if (_running || _stopped) return;
    _running = true;
    while (!paused && !_stopped) {
      final job = where(JobStatus.queued).firstOrNull;
      if (job == null) break;
      job.halt = false;
      await fetchChapter(job);
      if (jobs[job.chapter.url] != job) continue; // removed meanwhile
      switch (job.status) {
        case JobStatus.done:
          onDisk.add(job.chapter.url);
          jobs.remove(job.chapter.url);
          final where = job.dir.substring(Fs.scriptDir().path().length + 1);
          lines.add('✓ ${job.chapter.title}: ${job.total} pages → $where');
        case JobStatus.failed:
          final pages = job.missing.isEmpty ? '' : '${job.missing.length} pages failed, ';
          lines.add('✗ ${job.chapter.title}: $pages${job.error}');
        case JobStatus.paused when !paused: // resumed before it stopped
          job.status = JobStatus.queued;
        case _:
      }
    }
    _running = false;
  }
}

final queue = Queue();
