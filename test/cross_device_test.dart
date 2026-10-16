// Moves between two devices take the copy-then-delete fallbacks (a rename
// fails with EXDEV): the system temp folder and a RAM disk mounted inside it.
@Tags(['slow'])
@TestOn('mac-os')
library;

import 'dart:io' as io;

import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:test/test.dart';

/// Mount a fresh 8 MB RAM disk at [at] until the test ends; false when this
/// Mac cannot (no hdiutil, or a sandbox refuses it).
Future<bool> _ramDisk(String at) async {
  try {
    final made = await io.Process.run('hdiutil', ['attach', '-nomount', 'ram://16384']);
    final dev = '${made.stdout}'.trim().split(RegExp(r'\s+')).first;
    if (made.exitCode != 0 || !dev.startsWith('/dev/disk')) return false;
    // Only the device this test attached is ever detached.
    addTearDown(() => io.Process.run('hdiutil', ['detach', '-force', dev]));
    if ((await io.Process.run('newfs_hfs', ['-v', 'dtk-cross', dev])).exitCode != 0) return false;
    await io.Directory(at).create(recursive: true);
    // BSD mount and umount: DiskArbitration's unmount waits 10 s.
    if ((await io.Process.run('mount', ['-t', 'hfs', '-o', 'nobrowse', dev, at])).exitCode != 0) return false;
    addTearDown(() => io.Process.run('umount', ['-f', at]));
    return true;
  } on io.ProcessException {
    return false;
  }
}

void main() {
  late String tmp, ram;

  setUp(() async {
    tmp = (await io.Directory.systemTemp.createTemp('cross_device')).path;
    ram = '$tmp/ram';
    // Registered first, so it runs after the detach.
    addTearDown(() => io.Directory(tmp).delete(recursive: true));
  });

  Future<bool> mounted() async => await _ramDisk(ram) && (await io.File('$ram/.probe').create()).existsSync();

  test('File.move: content and mtime arrive, the source goes, a probe counts the bytes', () async {
    if (!await mounted()) return markTestSkipped('no RAM disk here');
    final when = DateTime(2020, 1, 2, 3, 4, 5);
    final src = await Fs.file('$tmp/a.bin').write('x' * 100000);
    await io.File(src.path).setLastModified(when);
    final meter = Meter();
    final moved = await (src.move('$ram/in/a.bin') & meter);
    expect(await moved.text(), 'x' * 100000);
    expect(await moved.modified(), when);
    expect(await src.exists(), isFalse);
    expect((meter.done(), meter.total()), (100000, 100000));
    await Fs.file('$ram/in/a.bin').move('$tmp/back.bin'); // and back, unwatched
    expect(await Fs.file('$tmp/back.bin').text(), 'x' * 100000);
  });

  test('Dir.move: the tree arrives and the source goes; an existing destination keeps both', () async {
    if (!await mounted()) return markTestSkipped('no RAM disk here');
    await Fs.file('$tmp/d/a.txt').write('a');
    await Fs.file('$tmp/d/sub/b.txt').write('b');
    await io.Link('$tmp/d/ln').create('a.txt');
    await Fs.dir('$tmp/d').move('$ram/d');
    expect(await Fs.file('$ram/d/sub/b.txt').text(), 'b');
    expect(await io.Link('$ram/d/ln').target(), 'a.txt');
    expect(io.Directory('$tmp/d').existsSync(), isFalse);
    // Never merge into, or delete the source over, what is already there.
    await Fs.file('$tmp/e/a.txt').write('mine');
    await Fs.file('$ram/e/z.txt').write('theirs');
    await expectLater(Fs.dir('$tmp/e').move('$ram/e'), throwsA(isA<io.FileSystemException>()));
    expect(await Fs.file('$tmp/e/a.txt').text(), 'mine');
    expect(io.File('$ram/e/a.txt').existsSync(), isFalse);
  });

  test('Link.move: the link is made again on the other device', () async {
    if (!await mounted()) return markTestSkipped('no RAM disk here');
    await io.Link('$tmp/ln').create('/some/where');
    await (await Fs.entry('$tmp/ln'))!.move('$ram/ln');
    expect(await io.Link('$ram/ln').target(), '/some/where');
    expect(io.Link('$tmp/ln').existsSync(), isFalse);
  });

  test('unarchive: members land in a folder that is another device', () async {
    if (!await mounted()) return markTestSkipped('no RAM disk here');
    await Fs.file('$tmp/src/ram/f.txt').write('file');
    await Fs.file('$tmp/src/ram/sub/g.txt').write('deep');
    await io.Link('$tmp/src/ram/ln').create('f.txt');
    await (Archive.archive(['ram'], dir: '$tmp/src', format: ArchiveFormat.tar) > Fs.file('$tmp/a.tar'));
    // The staging folder sits beside the target ($tmp), so every member
    // under ram/ crosses to the RAM disk.
    await (Fs.file('$tmp/a.tar') > Archive.unarchive(tmp));
    expect(await Fs.file('$ram/f.txt').text(), 'file');
    expect(await Fs.file('$ram/sub/g.txt').text(), 'deep');
    expect(await io.Link('$ram/ln').target(), 'f.txt');
    expect(io.Directory(tmp).listSync().where((e) => e.path.contains('.tmp')), isEmpty);
  });
}
