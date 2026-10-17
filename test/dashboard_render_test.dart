import 'package:dart_toolkit/src/tui.dart' show testSession;
import 'package:dart_toolkit/tui.dart';
import 'package:test/test.dart';

import '../projects/medialoader/dashboard.dart';
import '../projects/medialoader/db.dart';
import '../projects/medialoader/engine.dart';

void main() {
  test('medialoader dashboard layout renders with decoupled lanes and targets', () async {
    final db = MediaDb.memory();
    final engine = IngestionEngine(db: db, options: (all: false, dry: false, compress: false, since: null));

    final u1 = engine.getOrCreateUser('chunmomo0127', 'twt');
    u1.id = 'chunmomo0127';
    u1.category('posts')
      ..had = 10
      ..added = 2
      ..queued = 15;
    u1.category('profiles')
      ..had = 2
      ..added = 1
      ..queued = 3
      ..note = '2 profile assets'
      ..busy = false;

    final u2 = engine.getOrCreateUser('yang_sunshine', 'ins');
    u2.id = 'yang_sunshine';
    u2.category('posts')
      ..had = 50
      ..added = 5
      ..queued = 60;

    // Simulate active downloading lane
    final lane1 = engine.lanes[0];
    lane1.busy = true;
    lane1.platform = 'twt';
    lane1.user = 'chunmomo0127';
    lane1.file = 'posts/2026-10/photo1.jpg';
    lane1.status = LaneStatus.downloading;
    lane1.meter.update(1500000, 3000000);

    // Simulate active transcoding lane
    final lane2 = engine.lanes[1];
    lane2.busy = true;
    lane2.platform = 'ins';
    lane2.user = 'yang_sunshine';
    lane2.file = 'posts/2026-10/video.mp4';
    lane2.status = LaneStatus.transcoding;

    final dash = Dashboard(engine: engine, db: db);
    final t = testSession<Dashboard>(
      dash,
      (state, app) => Screen(state.draw, title: state.title()),
      width: 100,
      height: 24,
    );
    await t.pump();

    // Check title
    expect(t.row(0), contains('medialoader'));
    expect(t.row(0), contains('2 users'));

    // Check targets panel
    expect(t.row(1), contains('targets (2)'));

    // Check lanes rendered
    final rendered = [for (var i = 0; i < 24; i++) t.row(i)].join('\n');
    expect(rendered, contains('lanes:'));
    expect(rendered, contains('#1'));
    expect(rendered, contains('#2'));
    expect(rendered, contains('#8'));
    expect(rendered, contains('#10'));
    expect(rendered, contains('— idle —'));

    // Check status bar panel with rate limits and RAM
    expect(rendered, contains('status'));
    expect(rendered, contains('rate limit:'));
    expect(rendered, contains('RAM:'));
    expect(rendered, contains('[twt]'));
    expect(rendered, contains('[ins]'));

    db.close();
  });
}
