// One download queue for every user: files download 8 at a time from the
// CDNs, then compress (outside the lanes) when asked.
library;

import 'dart:convert';
import 'dart:math';

import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/image.dart';
import 'package:dart_toolkit/pool.dart';
import 'package:dart_toolkit/video.dart';

import 'dashboard.dart';
import 'job.dart';

// Images and videos come from the CDNs: no rate limit, retries, resumes.
final cdn = Http.client(retries: 3, resume: true);

final class Queue {
  Queue(this.o);
  final Options o;
  final _lanes = Pool(limit: 8);

  // Queues [files] for [j]; completes when the whole batch is done.
  Future<Results> add(Job j, List<Download> files) async {
    final missing = await Future.wait([for (final f in files) f.to.exists().then((e) => !e)]);
    for (final (i, f) in files.indexed) {
      if (missing[i]) _part(j, f).queued++;
    }
    return Pool.settle(files, (f) => _get(j, f), limit: max(files.length, 1));
  }

  // The folder a file lands in is its part: posts/2024-05/x.jpg → posts.
  Part _part(Job j, Download f) {
    final key = f.to.path(from: j.dir).split('/').first;
    return j.u.parts.putIfAbsent(key, () => Part(key));
  }

  Future<bool> _get(Job j, Download f) async {
    final part = _part(j, f), t = Transfer(j.u, part, f.to.path(from: j.dir));
    try {
      final isNew = await save(j, f, t);
      if (isNew) part.added++;
      return isNew;
    } catch (e) {
      part
        ..failed += 1
        ..bytes -= t.done;
      board.fail('✗ @${j.u.name} ${t.path}: $e', () async {
        part
          ..failed -= 1
          ..queued -= 1;
        await add(j, [f]);
      }, platform: j.code);
      rethrow;
    }
  }

  // Fetches (or writes) one file unless it is there; true when new.
  Future<bool> save(Job j, Download f, Transfer t) async {
    if (await f.to.exists()) return false;
    if (o.dry) {
      board.note('@${j.u.name} would save ${t.path}', platform: j.code);
      return true;
    }
    if (f.text case final text?) {
      await f.to.write(text);
      t.part.bytes += utf8.encode(text).length;
    } else {
      var how = '';
      try {
        await _lanes.run(() {
          board.transfers.add(t);
          return cdn.get(f.url!, headers: {'referer': '${j.platform.site}/'}) | board.speed | Pipe.tap(t.update) > f.to;
        });
        how = await _compress(f, t);
      } finally {
        board.transfers.remove(t);
      }
      board.note('@${j.u.name} ${t.path}  ${t.done.size()}$how', platform: j.code);
    }
    if (f.at case final at?) await f.to.touch(at);
    return true;
  }

  // Re-encodes the file at --image-quality/--video-quality; says how it went.
  Future<String> _compress(Download f, Transfer t) async {
    final path = f.to.path();
    final video = const {'mp4', 'mov', 'webm', 'mkv'}.contains(path.split('.').last.toLowerCase());
    final quality = video ? o.video : o.image;
    if (quality == null) return '';
    t.status = 'compressing';
    try {
      final r = video ? await Video.compress(path, quality: quality) : await Image.compress(path, quality: quality);
      if (r == null) return ' (kept: compressing would not make it smaller)';
      final (before, after) = r;
      t.part.bytes += after - before;
      return ' (compressed from ${before.size()}, -${((before - after) * 100 / before).round()}%)';
    } on ToolkitException catch (e) {
      return ' (not compressed: ${e.message})';
    } finally {
      t.status = null;
    }
  }
}
