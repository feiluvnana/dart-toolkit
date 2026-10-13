/// rawfree: search manga, pick a series, pick chapters, download.
///
/// ```sh
/// dart run example/rawfree.dart [initial query]
/// ```
///
/// Pure console flow, one step per screen: ask for a search query, choose
/// a series from the results (`⋯ load more` pages in older results),
/// choose chapters (`⋯ load more` pages in older chapters, `all` pulls the
/// rest first), download. Each menu clears the screen; results stay up
/// until any keypress. Pages land in
/// `downloads/<series>/<chapter>/001.jpg`, … Navigate with `w`/`s` (or
/// `↑`/`↓` where the terminal delivers arrows), `1`-`9` jumps to a row,
/// Enter picks; `b` goes back, `o` opens the browser, `q` quits — no
/// Enter needed, so consoles without working arrows/escape stay usable.
library;

import 'dart:io' show exit, stderr;

import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';

import 'rawfree/api.dart';

const _newSearch = '↩ New search [b]';
const _backToSeries = '↩ Back to series [b]';
const _openBrowser = '🌐 Open series in browser [o]';
const _quit = '✕ Quit [q]';

Future<void> main([List<String> args = const []]) async {
  await runConsole(args.join(' ').trim());
  exit(0);
}

Future<void> runConsole(String initialQuery) async {
  // Interactive-first: always style the menus, even with NO_COLOR set
  // (the library default honors it; remove this to follow the convention).
  Console.forceColor = true;
  var query = initialQuery.trim();
  // Outer loop: one search per iteration. Setting [query] to '' prompts
  // again on the next pass. The browsing menus clear the screen; the
  // search line keeps its scrollback history like any CLI prompt, so its
  // header is never wiped. Messages printed before navigating away wait
  // for a keypress first — see [_pause].
  while (true) {
    if (query.isEmpty) {
      try {
        query =
            (await Console.ask(
              '✻ rawfree — enter manga title to search (or empty to quit):',
            )).trim();
      } catch (_) {
        return; // stdin closed
      }
      if (query.isEmpty) return;
    }

    query = await _seriesMenu(query);
    if (_quitRequested) return;
  }
}

bool _quitRequested = false;

/// Search [query] (page 1), then browse the results until the user picks
/// "new search" (returns '') or quits (returns '' with [_quitRequested]
/// set). Older result pages load in place via `⋯ load more`.
Future<String> _seriesMenu(String query) async {
  SearchPage first;
  try {
    final q = query;
    first = await Console.spin(
      'searching for "$q"',
      () => searchManga(q),
    );
  } catch (e) {
    stderr.writeln('search failed: ${shortError(e)}');
    await _pause();
    return '';
  }
  final all = <Hit>[];
  final seenUrls = <String>{};
  _addHits(all, seenUrls, first.hits);
  if (all.isEmpty) {
    stderr.writeln('No manga found matching "$query".');
    await _pause();
    return '';
  }
  var page = 1;
  var hasMore = first.hasMore;
  var keepIndex = 0;

  while (true) {
    final labels = _uniqueLabels([for (final h in all) h.title]);
    final byLabel = {for (var i = 0; i < all.length; i++) labels[i]: all[i]};
    final moreLabel = '⋯ Load more results (page ${page + 1})';
    final String choice;
    try {
      choice = await Console.choose(
        'Results for "$query" — pick a series:',
        [...labels, if (hasMore) moreLabel, _newSearch, _quit],
        clear: true,
        initial: keepIndex,
        escapeValue: _newSearch,
        shortcuts: const {'b': _newSearch, 'q': _quit},
      );
    } catch (_) {
      _quitRequested = true;
      return '';
    }
    keepIndex = 0;
    if (choice == _newSearch) return '';
    if (choice == _quit) {
      _quitRequested = true;
      return '';
    }
    if (choice == moreLabel) {
      page++;
      try {
        final next = await Console.spin(
          'loading results (page $page)…',
          () => searchManga(query, page: page),
        );
        keepIndex = labels.length; // first newly loaded row
        _addHits(all, seenUrls, next.hits);
        hasMore = next.hasMore;
      } catch (e) {
        page--;
        stderr.writeln('load more failed: ${shortError(e)}');
        await _pause();
      }
      continue;
    }
    final hit = byLabel[choice];
    if (hit == null) continue; // cannot happen; re-prompt
    final next = await _chapterMenu(hit);
    if (next == _ChapterExit.newSearch || next == _ChapterExit.quit) {
      if (next == _ChapterExit.quit) _quitRequested = true;
      return '';
    }
    // _ChapterExit.back: pick another series from the same results.
  }
}

enum _ChapterExit { back, newSearch, quit }

/// Chapters of [hit] until back / new search / quit. Older chapter pages
/// load in place; `all` pulls the remaining pages before downloading.
Future<_ChapterExit> _chapterMenu(Hit hit) async {
  ChapterPage first;
  try {
    first = await Console.spin(
      'loading chapters for ${hit.title}',
      () => resolveChapters(hit.url),
    );
  } catch (e) {
    stderr.writeln('failed to load chapters: ${shortError(e)}');
    await _pause();
    return _ChapterExit.back;
  }
  final all = [...first.chapters];
  if (all.isEmpty) {
    stderr.writeln('No chapters found for ${hit.title}.');
    await _pause();
    return _ChapterExit.back;
  }
  var page = 1;
  var hasMore = first.hasMore;
  var keepIndex = 0;

  while (true) {
    final labels = _uniqueLabels([for (final c in all) c.title]);
    final byLabel = {for (var i = 0; i < all.length; i++) labels[i]: all[i]};
    final allLabel = 'All chapters (${all.length}${hasMore ? '+' : ''})';
    final moreLabel = '⋯ Load older chapters (page ${page + 1})';
    final String choice;
    try {
      choice = await Console.choose(
        'Chapters of ${hit.title} — pick to download:',
        [
          allLabel,
          ...labels,
          if (hasMore) moreLabel,
          _openBrowser,
          _backToSeries,
          _newSearch,
          _quit,
        ],
        clear: true,
        initial: keepIndex,
        escapeValue: _backToSeries,
        shortcuts: const {
          'b': _backToSeries,
          'o': _openBrowser,
          'q': _quit,
        },
      );
    } catch (_) {
      return _ChapterExit.quit;
    }
    keepIndex = 0;
    if (choice == _quit) return _ChapterExit.quit;
    if (choice == _newSearch) return _ChapterExit.newSearch;
    if (choice == _backToSeries) return _ChapterExit.back;
    if (choice == _openBrowser) {
      try {
        await openSeries(hit);
        stderr.writeln('opened in browser');
      } catch (e) {
        stderr.writeln('browser failed: ${shortError(e)}');
        await _pause();
      }
      continue;
    }
    if (choice == moreLabel) {
      page++;
      try {
        final next = await Console.spin(
          'loading chapters (page $page)…',
          () => resolveChapters(hit.url, page: page),
        );
        keepIndex = labels.length + 1; // first newly loaded row
        all.addAll(next.chapters);
        hasMore = next.hasMore;
      } catch (e) {
        page--;
        stderr.writeln('load more failed: ${shortError(e)}');
        await _pause();
      }
      continue;
    }
    if (choice == allLabel) {
      // Pull the remaining pages so "all" really means all.
      while (hasMore) {
        page++;
        try {
          final next = await Console.spin(
            'loading chapters (page $page)…',
            () => resolveChapters(hit.url, page: page),
          );
          all.addAll(next.chapters);
          hasMore = next.hasMore;
        } catch (e) {
          page--;
          stderr.writeln('page $page failed: ${shortError(e)}');
          break;
        }
      }
      await _downloadAll(hit, all);
      if (_quitRequested) return _ChapterExit.quit;
      await _pause();
      continue;
    }
    final chapter = byLabel[choice];
    if (chapter == null) continue; // cannot happen; re-prompt
    await _downloadChapters(hit, [chapter]);
    if (_quitRequested) return _ChapterExit.quit;
    await _pause();
  }
}

/// Let the user read a transient message before the next menu clears it.
/// Never throws: on a closed stdin the next prompt fails naturally, which
/// exits the app through the usual paths — so a pause can never strand or
/// quit the flow by itself.
Future<void> _pause() async {
  try {
    await Console.key(prompt: 'Press any key to continue…');
  } catch (_) {
    // Ignored: the next prompt fails naturally on a closed stdin.
  }
}

/// Append [hits], skipping URLs already collected (tags and posts overlap
/// across pages).
void _addHits(List<Hit> into, Set<String> seenUrls, List<Hit> hits) {
  for (final h in hits) {
    if (seenUrls.add(h.url)) into.add(h);
  }
}

/// "All" skips chapters already on disk.
Future<void> _downloadAll(Hit hit, List<Chapter> chapters) async {
  final fresh = <Chapter>[];
  var skipped = 0;
  for (final c in chapters) {
    if (await Fs.dir(Job(hit, c).dir).exists()) {
      skipped++;
    } else {
      fresh.add(c);
    }
  }
  if (fresh.isEmpty) {
    stderr.writeln('all ${chapters.length} chapter(s) already on disk.');
    return;
  }
  if (skipped > 0) {
    stderr.writeln('skipping $skipped chapter(s) already on disk.');
  }
  await _downloadChapters(hit, fresh);
}

Future<void> _downloadChapters(Hit hit, List<Chapter> chapters) async {
  final failed = <Job>[];
  for (final chapter in chapters) {
    final job = Job(hit, chapter)..status = JobStatus.active;
    Bar? bar;
    try {
      await fetchChapter(
        job,
        onTotal: (total) {
          bar ??= Console.bar(total, label: '⇣ ${chapter.title}');
        },
        onTick: () => bar?.tick(),
      );
    } catch (e) {
      job.status = JobStatus.failed;
      job.error ??= shortError(e);
    } finally {
      await bar?.close();
    }
    if (job.status == JobStatus.done) {
      stderr.writeln('✓ ${chapter.title} → ${job.dir}');
    } else {
      failed.add(job);
      stderr.writeln(
        '✗ ${chapter.title} (${job.missing.length} pages failed${job.error == null ? '' : ': ${job.error}'})',
      );
    }
  }
  // Retry reuses the same jobs, so only the missing pages are refetched.
  // `q` quits the retry loop outright, without Enter.
  while (failed.isNotEmpty) {
    stderr.writeln(
      'Retry ${failed.length} failed chapter(s)? [y]es / [n]o / [q]uit',
    );
    final String answer;
    try {
      answer = (await Console.key()).trim().toLowerCase();
    } catch (_) {
      return;
    }
    if (answer == 'q') {
      _quitRequested = true;
      return;
    }
    if (answer != 'y' && answer != 'enter') return;
    final todo = [...failed];
    failed.clear();
    for (final job in todo) {
      job.status = JobStatus.active;
      Bar? bar;
      try {
        await fetchChapter(
          job,
          onTotal: (total) {
            bar ??= Console.bar(total, label: '⇣ ${job.chapter.title}');
          },
          onTick: () => bar?.tick(),
        );
      } catch (e) {
        job.status = JobStatus.failed;
        job.error ??= shortError(e);
      } finally {
        await bar?.close();
      }
      if (job.status == JobStatus.done) {
        stderr.writeln('✓ ${job.chapter.title} → ${job.dir}');
      } else {
        failed.add(job);
        stderr.writeln(
          '✗ ${job.chapter.title} (${job.missing.length} pages failed${job.error == null ? '' : ': ${job.error}'})',
        );
      }
    }
  }
}

/// Choice labels that stay unique when two results share a title.
List<String> _uniqueLabels(List<String> titles) {
  final counts = <String, int>{};
  for (final t in titles) {
    counts[t] = (counts[t] ?? 0) + 1;
  }
  final seen = <String, int>{};
  return [
    for (final t in titles)
      if (counts[t]! > 1)
        '$t [${(seen[t] = (seen[t] ?? 0) + 1)}]'
      else
        t,
  ];
}
