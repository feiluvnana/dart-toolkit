# Module Proposal 11: Terminal UI (TUI) & Widgets (`lib/tui.dart`)

## 1. Overview & Vision

The TUI module provides full-screen interactive terminal applications, sub-millisecond cell buffer diffing, ANSI mouse & keyboard event loops, responsive layout containers, and built-in interactive widgets (`Field`, `Button`, `Menu`, `Gauge`, `Markdown`, `Picture`).

### Core Problems in the Existing API
1. **Low-Level Event Loop Boilerplate**: Building an interactive application requires writing a complex event handling loop with raw event matching.
2. **State Management Ceremony**: Wiring application state to screen redraws requires manual message dispatching (`Post(event)`).
3. **Layout Composition Friction**: Composing complex responsive layouts with headers, footers, sidebars, and panels requires manual size constraint arithmetic.

---

## 2. Detailed Before vs After Comparison

### 2.1 Declarative Widget Tree & State Container

#### Before:
```dart
// Low-level app setup with manual screen switching and message dispatch
```

#### After (Proposed):
```dart
// ==================== PROPOSED DECLARATIVE TUI APP ====================
void main() => Tui.app<AppState>(
  initial: AppState.init(),
  update: (state, event) => switch (event) {
    KeyPress(key: 'q') => state.exit(),
    KeyPress(key: 'r') => state.reload(),
    KeyPress(key: 'ArrowDown') => state.next(),
    KeyPress(key: 'ArrowUp') => state.previous(),
    _ => state,
  },
  view: (state) => VStack([
    Header('Server Cluster Monitor', subtitle: 'Region: us-east-1'),
    Divider(),
    HStack([
      Sidebar(nodes: state.nodes, selectedIndex: state.selectedNode),
      VStack([
        Gauge(label: 'CPU Usage', value: state.cpuUsage, color: Color.green),
        Gauge(label: 'Memory', value: state.memUsage, color: Color.yellow),
        LogPanel(logs: state.recentLogs),
      ]),
    ]),
    Footer('[q] Quit  [r] Refresh  [↑/↓] Select Node'),
  ]),
);
```

##### Visual Look (Terminal Render):
```text
┌─ Server Cluster Monitor ───────────────────────────── Region: us-east-1 ─┐
│                                                                          │
│  NODES                     CPU Usage                                     │
│  › [●] node-01.prod        ━━━━━━╸──────────────  32%                    │
│    [●] node-02.prod                                                      │
│    [●] node-03.prod        Memory                                        │
│    [○] node-04.idle        ━━━━━━━━━━━━╸────────  64% (10.2 / 16.0 GB)   │
│                                                                          │
│                            RECENT LOGS                                   │
│                            21:42:01 [info] Health check OK (12ms)        │
│                            21:42:05 [info] GET /api/v1/metrics (200 OK)  │
│                            21:42:10 [warn] High memory on redis-cache    │
│                                                                          │
└─ [q] Quit  [r] Refresh  [↑/↓] Select Node ───────────────────────────────┘
```

---

### 2.2 Instant Dialogs & Overlays

#### Before:
```dart
// Required custom popup stack calculations
```

#### After (Proposed):
```dart
// Modal alerts & confirmation dialogs
await Tui.alert('Deployment Failed', message: 'Could not connect to database host.');

final confirmed = await Tui.confirm(
  'Confirm Action',
  message: 'Are you sure you want to drop the database?',
);
```

##### Visual Look (Modal Alert Overlay):
```text
  ┌─ Confirm Action ──────────────────────────┐
  │                                           │
  │  Are you sure you want to drop database?  │
  │                                           │
  │           [ Yes ]     [ No ]              │
  └───────────────────────────────────────────┘
```

---

## 3. What is Better vs Old API

| Feature | Old API | Proposed New API | Impact |
|---|---|---|---|
| **App Structure** | Imperative event matching | Declarative `update` + `view` cycle | Flutter/SwiftUI familiar paradigm |
| **Widget Layout** | Manual bounds calculations | `VStack`, `HStack`, `Expanded`, `Flex` | Automatic responsive terminal resizing |
| **Dialogs** | Manual popup widget layering | `Tui.alert()`, `Tui.confirm()` | 1-line interactive modals |

---

## 4. Trade-Offs & Backward Compatibility

### Trade-Offs:
- The declarative `view: (state) => Widget` rebuilds the virtual widget tree on state update, and the cell buffer diffing engine only paints terminal cells that actually changed. This provides 60fps performance with negligible CPU usage.

### Backward Compatibility:
- 100% backward compatible. All existing low-level widgets (`Box`, `Field`, `Spin`, `Scroll`, `Board`, `Canvas`, `Tui.run`) remain completely available.
