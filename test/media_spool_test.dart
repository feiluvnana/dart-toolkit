// Spooled media temps: a failed source leaves nothing, and a script that
// ends leaves none of its spools behind (B17).
import 'dart:io';

import 'package:dart_toolkit/src/media.dart' as media;
import 'package:test/test.dart';

import 'support/child.dart';
import 'support/poll.dart';

void main() {
  test('a source that fails while spooling leaves no partial file', () async {
    final kept = await media.spool(Stream.value([1, 2, 3]));
    addTearDown(() => File(kept).delete().catchError((_) => File(kept)));
    Stream<List<int>> failing() async* {
      yield [4, 5, 6];
      throw StateError('source blew up');
    }

    await expectLater(media.spool(failing()), throwsStateError);
    final left = await Directory(File(kept).parent.path).list().map((e) => e.path).toList();
    expect(left, [kept]);
  });

  test('a script that ends leaves no spool behind', () async {
    final r = await runDart('''
import 'package:dart_toolkit/src/media.dart' as media;
Future<void> main() async {
  print(await media.spool(Stream.value([1, 2, 3])));
}
''');
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final spooled = (r.stdout as String).trim();
    expect(await eventually(() => !File(spooled).existsSync()), isTrue, reason: spooled);
    expect(await eventually(() => !Directory(File(spooled).parent.path).existsSync()), isTrue);
  }, skip: Platform.isWindows ? 'the exit watchdog is POSIX only' : null);
}
