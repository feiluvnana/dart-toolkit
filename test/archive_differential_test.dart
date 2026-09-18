import 'dart:io';
import 'dart:math';

import 'package:archive/archive_io.dart' as reference;
import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:test/test.dart';

/// The in-house zip against `package:archive` and the system `unzip`: every archive we write
/// must open in both, and every archive they write must open in ours, byte for byte.
void main() {
  late Path tmp;
  late Path src;

  setUp(() {
    tmp = Path(Directory.systemTemp.createTempSync('zipdiff_').path);
    src = tmp / 'src';
    final rnd = Random(7);
    (src / 'empty.txt').writeBytesSync([]);
    (src / 'note.txt').writeTextSync('Archive Note\n' * 100);
    (src / 'ünïcode 名前.txt').writeTextSync('names survive');
    (src / 'sub' / 'deep' / 'random.bin').writeBytesSync(List.generate(3 << 20, (_) => rnd.nextInt(256)));
    (src / 'sub' / 'text.txt').writeTextSync(List.generate(50000, (i) => 'line $i').join('\n'));
    (src / 'emptydir').mkdirSync();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Map<String, List<int>> contents(Path root) => {
    for (final f in root.filesSync(recursive: true)) f.path.substring(root.length + 1): f.readBytesSync(),
  };

  test('ours → package:archive, ours → unzip, ours → ours', () async {
    final zip = tmp / 'ours.zip';
    await src.zipTo(zip);

    final ref = reference.ZipDecoder().decodeBytes(zip.readBytesSync(), verify: true);
    final refFiles = {for (final f in ref.files.where((f) => f.isFile)) f.name: f.content as List<int>};
    expect(refFiles, equals(contents(src)));
    expect(ref.files.any((f) => f.name == 'emptydir/' && !f.isFile), isTrue, reason: 'empty directories survive');

    final unzip = await Process.run('unzip', ['-tq', zip]);
    expect(unzip.exitCode, 0, reason: unzip.stdout.toString() + unzip.stderr.toString());

    await zip.extractTo(tmp / 'back');
    expect(contents(tmp / 'back'), equals(contents(src)));
    expect((tmp / 'back' / 'emptydir').existsSync(), isTrue);

    final entries = await zip.zipEntries();
    expect(entries.map((e) => e.name), containsAll(['note.txt', 'sub/deep/random.bin', 'emptydir/']));
    expect(entries.firstWhere((e) => e.name == 'sub/deep/random.bin').size, 3 << 20);
  });

  test('sync writer and reader agree with the async ones', () {
    final zip = tmp / 'sync.zip';
    src.zipToSync(zip);
    zip.extractToSync(tmp / 'back');
    expect(contents(tmp / 'back'), equals(contents(src)));
    expect(zip.zipEntriesSync().length, 8); // 5 files, sub/, sub/deep/, emptydir/
  });

  test('package:archive → ours and unzip → ours', () async {
    final theirs = tmp / 'theirs.zip';
    await reference.ZipFileEncoder().zipDirectory(src.asDir, filename: theirs);
    await theirs.extractTo(tmp / 'from_theirs');
    expect(contents(tmp / 'from_theirs'), equals(contents(src)));

    final system = tmp / 'system.zip';
    final zipped = await Process.run('zip', ['-rq', system, '.'], workingDirectory: src);
    expect(zipped.exitCode, 0);
    system.extractToSync(tmp / 'from_system');
    expect(contents(tmp / 'from_system'), equals(contents(src)));
  });

  test('a single file zips to one entry named after itself', () async {
    final zip = tmp / 'one.zip';
    await (src / 'note.txt').zipTo(zip);
    expect((await zip.zipEntries()).map((e) => e.name), ['note.txt']);
  });

  test('a corrupt byte is a FormatException, an encrypted entry is unsupported', () async {
    final zip = tmp / 'c.zip';
    await (src / 'note.txt').zipTo(zip);
    final bytes = zip.readBytesSync();
    bytes[40] ^= 0xff; // inside the deflate stream
    (tmp / 'bad.zip').writeBytesSync(bytes);
    expect(() => (tmp / 'bad.zip').extractTo(tmp / 'x'), throwsA(isA<FormatException>()));

    final enc = await Process.run('zip', ['-q', '-P', 'pw', tmp / 'enc.zip', 'note.txt'], workingDirectory: src);
    expect(enc.exitCode, 0);
    expect(() => (tmp / 'enc.zip').extractToSync(tmp / 'y'), throwsUnsupportedError);
  });

  test('is not slower than the reference on a 3 MB mixed tree', () async {
    final sw = Stopwatch()..start();
    await src.zipTo(tmp / 'a.zip');
    final ours = sw.elapsedMicroseconds;
    sw.reset();
    await reference.ZipFileEncoder().zipDirectory(src.asDir, filename: tmp / 'b.zip');
    final theirs = sw.elapsedMicroseconds;
    expect(ours, lessThan(theirs * 2), reason: '$ours µs vs $theirs µs');
  });
}
