# 12: TUI (Terminal User Interface)

High-performance, flicker-free terminal applications powered by Rust `ratatui` & `crossterm` via native FFI.

---

## 1. Quick App Lifecycle (`run`)

Enters raw mode, alternate screen, and handles terminal cleanup automatically on exit:

```dart
void main() async {
  await Tui.run((term) async {
    while (true) {
      term.draw((ui) {
        ui.box(title: 'App');
        ui.text('Press "q" to exit.');
      });

      final ev = await term.poll();
      if (ev.key == 'q') break;
    }
  });
}
```

---

## 2. Layouts & Widgets

Declarative, short 1-word widgets rendered via Rust's double-buffered diff engine:

```dart
term.draw((ui) {
  // Horizontal or vertical split
  ui.split(vert: false, [
    (left) {
      left.box(title: 'Menu');
      left.list(['Overview', 'Settings', 'Logs'], sel: 0);
    },
    (right) {
      right.box(title: 'Details');
      right.text('Server: online', color: 'green');
      right.bar(val: 64, max: 100, label: 'Memory');
    },
  ]);
});
```

---

## 3. Events (`poll`)

Captures keyboard, mouse, and resize events:

```dart
final ev = await term.poll(timeout: const Duration(milliseconds: 50));

if (ev case KeyEvent(:final key)) {
  switch (key) {
    case 'up':   sel--;
    case 'down': sel++;
    case 'enter': openItem(sel);
    case 'q':    break;
  }
}
```

---

## 4. Advanced Use Cases

### 4.1 Real-Time Worker Dashboard with `Chan` & `Tui`
Connect background worker threads to a live TUI monitor without frame rate drops:

```dart
void main() async {
  final updates = Chan<WorkerStat>(cap: 100);
  final stats   = <String, int>{};

  // Background worker pushing metrics
  Task.run(() async {
    while (true) {
      await updates.send(WorkerStat('cpu', getCpuLoad()));
      await Future.delayed(const Duration(milliseconds: 200));
    }
  });

  // TUI Event & Render Loop
  await Tui.run((term) async {
    while (true) {
      // Drain channel updates non-blocking
      while (updates.tryRecv() case final stat?) {
        stats[stat.name] = stat.val;
      }

      term.draw((ui) {
        ui.box(title: 'Live Monitor');
        ui.bar(val: stats['cpu'] ?? 0, max: 100, label: 'CPU');
      });

      final ev = await term.poll(timeout: const Duration(milliseconds: 100));
      if (ev.key == 'q') break;
    }
  });
}
```

### 4.2 Interactive File Explorer with Keybindings
```dart
void explore(Dir root) async {
  var files = await root.find('*');
  var sel = 0;

  await Tui.run((term) async {
    while (true) {
      term.draw((ui) {
        ui.box(title: root.path);
        ui.list(files.map((f) => f.name).toList(), sel: sel);
      });

      final ev = await term.poll();
      if (ev.key == 'up' && sel > 0) sel--;
      if (ev.key == 'down' && sel < files.length - 1) sel++;
      if (ev.key == 'q') break;
    }
  });
}
```
