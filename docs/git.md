# Git Automation Subsystem (`util.git.*`)

The `util.git` sub-namespace in **Dart Script Toolkit** provides streamlined repository inspection, staging, committing, and synchronization using external `git` binary execution.

All methods strictly adhere to the **1-word method naming convention**.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  // 1. Inspect repository state
  final branch = await util.git.branch();
  final hash = await util.git.hash();
  final isDirty = await util.git.dirty();

  util.console.logger.info('Repo branch: $branch, commit: $hash, dirty: $isDirty');

  // 2. Automate commits if changes exist
  if (isDirty) {
    await util.git.add();
    await util.git.commit('chore: automated build update');
    await util.git.push();
    util.console.logger.ok('Pushed changes to remote repository.');
  }
}
```

---

## 1. Repository Inspection

Inspect repository status and metadata without writing boilerplate `Process.run` commands:

| Method | Return Type | Description |
| :--- | :--- | :--- |
| `util.git.branch([cwd])` | `Future<String>` | Returns the current active branch name (e.g. `'master'`, `'main'`). |
| `util.git.hash([short = true, cwd])` | `Future<String>` | Returns the commit SHA hash of `HEAD`. Pass `false` for the full 40-character SHA. |
| `util.git.dirty([cwd])` | `Future<bool>` | Checks whether there are uncommitted modifications or untracked changes. |
| `util.git.status([cwd])` | `Future<String>` | Returns the short porcelain status (`git status --short`). |
| `util.git.tag([name, cwd])` | `Future<String>` | If `name` is omitted, returns the latest or exact tag. If `name` is provided, creates a new lightweight tag. |

### Example
```dart
final branch = await util.git.branch();
final commit = await util.git.hash(true);
final status = await util.git.status();

if (await util.git.dirty()) {
  util.console.logger.warn('Working tree has changes:\n$status');
}
```

---

## 2. Staging & Committing

Stage and commit changes programmatically:

### `util.git.add([pattern = '.', cwd])`
Stages files matching `pattern` (defaults to all files `.`):
```dart
await util.git.add();
// Or stage specific path
await util.git.add('pubspec.yaml');
```

### `util.git.commit(msg, {bool all = false, String? cwd})`
Creates a git commit with the specified commit message. If `all` is `true`, passes `-a`:
```dart
final success = await util.git.commit('feat: add new CLI flag');
if (success) {
  util.console.logger.ok('Committed successfully.');
}
```

---

## 3. Remote Synchronization

Synchronize with remote repositories:

### `util.git.push([remote, branch, cwd])`
Pushes commits to the remote:
```dart
await util.git.push();
// Or push to specific upstream
await util.git.push('origin', 'main');
```

### `util.git.pull([remote, branch, cwd])`
Pulls updates from the remote:
```dart
await util.git.pull();
```

### `util.git.clone(repo, [dest, cwd])`
Clones a remote repository to an optional destination folder:
```dart
await util.git.clone('https://github.com/feiluvnana/dart-toolkit.git', 'toolkit-clone');
```

---

## 4. Arbitrary Git Commands (`util.git.run`)

Run any custom or advanced git command directly, returning a `SysResult`:

```dart
final res = await util.git.run(['log', '--oneline', '-n', '5']);
if (res.ok) {
  util.console.logger.info('Recent commits:\n${res.output}');
}
```
