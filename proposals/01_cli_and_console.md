# Module Proposal 01: CLI, Terminal & Console (`lib/cli.dart`)

## 1. Overview & Vision

The CLI and Console module provides command-line argument parsing, subcommands, interactive terminal prompts, progress indicators (spinners and multi-row bars), styled output, and terminal theme configuration.

### Core Problems in the Existing API
1. **Verbose Option Declarations**: Defining options requires detached `CliValue` instances (`final port = Option.of<int>('port').or(8080);`) outside the `Cli` constructor.
2. **Awkward Context Invocation**: Reading parsed values uses function call semantics on the context (`ctx(port)`), which feels unnatural in Dart and loses easy discoverability.
3. **Rigid Spinner & Task Endings**: `Task.show()` and `Console.bar()` have static completion messages with no easy way to dynamically update labels, sub-steps, or conditional completion texts (`done`, `skipped`, `failed`, `warned`) during execution.
4. **Scattered Prompt Names**: Interactive prompts had disparate naming conventions (`ask`, `confirm`, `secret`, `choose`, `multiChoose`).
5. **Theme Verbosity**: Customizing terminal themes required declaring verbose line formatters with boilerplate view unpacking.

---

## 2. Detailed Before vs After Comparison

### 2.1 CLI Definition & Option Parsing

#### Before:
```dart
final port = Option.of<int>('port', 'Server port', short: 'p').or(8080);
final env = Option.of<String>('env', 'Environment', choices: ['dev', 'prod']).or('dev');
final verbose = Option.flag('verbose', 'Verbose logs', short: 'v');
final targets = Arg.of<String>('targets', 'Files to process').many().required();

void main(List<String> args) => Cli(
  'File processing tool',
  options: [port, env, verbose],
  args: [targets],
  handler: (ctx) async {
    final p = ctx(port);          // type: int
    final e = ctx(env);           // type: String
    final v = ctx(verbose);       // type: bool
    final t = ctx(targets);       // type: List<String>
    print('Starting server on $p ($e)...');
  },
).run(args);
```

#### After (Proposed):
```dart
void main(List<String> args) => Cli('File processing tool', (cli) {
  cli.optInt('port', abbr: 'p', def: 8080, help: 'Server port');
  cli.optStr('env', abbr: 'e', def: 'dev', choices: ['dev', 'prod'], help: 'Environment');
  cli.flag('verbose', abbr: 'v', help: 'Verbose logs');
  cli.argList('targets', help: 'Files to process');

  // Direct subcommand declaration
  cli.command('clean', (sub) {
    sub.flag('all', abbr: 'a', help: 'Clean everything');
    sub.action((ctx) async => await cleanCache(all: ctx.flag('all')));
  });

  cli.action((ctx) async {
    final p = ctx.int('port');       // type: int (8080 by default)
    final e = ctx.str('env');        // type: String ('dev' by default)
    final v = ctx.flag('verbose');   // type: bool
    final t = ctx.list('targets');   // type: List<String>
    Console.info('Starting server on $p ($e)...');
  });
}).run(args);
```

---

### 2.2 Dynamic Spinners (Full State & Text Modification)

#### Before:
```dart
// Limited to static title and optional static done text
final result = await compile().show('Compiling', done: 'Compiled');
```

#### After (Proposed):
```dart
// 1. Interactive controller with runtime text and state changes
final result = await Console.spinner('Compiling assets...', (spin) async {
  spin.text = 'Parsing AST...';
  await parse();

  spin.step = 'Linking modules (3/10)';
  await link();

  if (isCached) {
    spin.skip('Using cached build artifacts');
    return cachedArtifact;
  }

  spin.done = 'Compiled 14 modules in ${spin.elapsed.humanized}';
  return buildArtifact;
});

// 2. Future extension with rich conditional messages
final data = await fetch().showSpinner(
  'Fetching remote data',
  done: 'Data synced successfully',
  failed: (err) => 'Sync failed: $err',
  skipped: 'Already up to date',
);
```

##### Visual Look:
```text
# Running state:
⠋ Compiling assets...  Linking modules (3/10)  (1.4s)

# Finished (Done):
✓ Compiled 14 modules in 1.8s (1.8s)

# Finished (Skipped):
- Compiling assets: Using cached build artifacts (45ms)

# Finished (Failed):
✖ Compiling assets: SyntaxError on line 42 (1.1s)
```

---

### 2.3 Dynamic Progress Bars & Batch Visualization

#### Before:
```dart
final bar = Console.bar('Syncing', count: files.length);
for (final file in files) {
  await sync(file);
  bar.tick(label: file.name);
}
await bar.close();
```

#### After (Proposed):
```dart
// 1. Direct scoped progress with auto-cleanup and dynamic text
await Console.progress('Syncing files', total: files.length, (bar) async {
  for (final file in files) {
    bar.text = 'Syncing ${file.name}';
    bar.step = 'Compressing...';
    
    await sync(file);
    
    bar.tick(1, label: file.name, step: 'Done');
  }
  bar.done = 'All ${files.length} files synced!';
});

// 2. Driving a parallel batch directly with Console.progress
final batch = urls.mapParallel((u) => u.download(to: dir / u.name), concurrency: 4);
await Console.progress('Downloading Album', batch, (ctrl) {
  ctrl.done = 'Album downloaded ready to listen!';
  ctrl.failed = (err) => 'Download stopped: $err';
});
```

##### Visual Look:
```text
⠙ Downloading Album  ━━━━━╸──────────────  12/50  3.4 MB/s  eta 1m 12s  (18s)
    01. Track One.flac                        ━━━━━━━╸────────  45%  12.4/28.0 MB  1.2 MB/s
    02. Track Two.flac                        ━━━━━━━━━━━━╸───  82%  22.1/27.0 MB  1.1 MB/s
    03. Track Three.flac                      ━━╸─────────────  15%   4.2/29.1 MB  950 KB/s
    04. Track Four.flac                       ────────╸───────   5%   1.1/24.0 MB  180 KB/s
    +46 more
```

---

### 2.4 Interactive Prompts (`choose` & `multi`)

#### Before:
```dart
final name = await Console.ask('Name');
final confirm = await Console.confirm('Continue?', or: true);
final secret = await Console.secret('Password');
// Multi-select required importing pick.dart and using low-level items
```

#### After (Proposed):
```dart
final name     = await Console.ask('Project Name', def: 'my_app');
final proceed  = await Console.confirm('Deploy to production?', def: false);
final apiKey   = await Console.secret('Enter Secret Token');

// Single choice menu
final env = await Console.choose('Select Environment', ['dev', 'staging', 'prod']);

// Multi choice menu (renamed from multiChoose to multi)
final features = await Console.multi(
  'Select Features to Install',
  ['Auth (JWT)', 'PostgreSQL DB', 'Redis Cache', 'GraphQL API'],
  checked: ['Auth (JWT)', 'PostgreSQL DB'],
);
```

##### Visual Look:
```text
? Select Features to Install (Space to toggle, Enter to confirm):
  › [x] Auth (JWT)
    [x] PostgreSQL DB
    [ ] Redis Cache
    [ ] GraphQL API
```

---

### 2.5 Cleaner Console Themes

#### Before:
```dart
final theme = ConsoleTheme(
  bar: BarGlyphs.line,
  task: (t) => '${t.frame} ${t.label} ${t.bar} ${t.amounts}',
  log: (l) => '[${l.level.name}] ${l.message}',
);
```

#### After (Proposed):
```dart
// 1. Presets
ConsoleTheme.clean();    // Sleek modern line glyphs and minimal accents
ConsoleTheme.minimal();  // Subtle dots and unstyled dividers
ConsoleTheme.fancy();    // Sub-block fractional blocks and full metrics
ConsoleTheme.ascii();    // Pure 7-bit ASCII for CI environments

// 2. Fluent chainable copyWith
final customTheme = ConsoleTheme.clean().copyWith(
  bar: BarGlyphs.smooth(),
  accent: Color.cyan,
  rows: 10,
);

// 3. Clean line overrides
final brandedTheme = ConsoleTheme.clean().withTask(
  (t) => '${t.frame} ${t.label.bold} ${t.bar} ${t.pace.dim}',
);

// 4. Scoped execution
await Console.scope(() => runTasks(), theme: brandedTheme);
```

---

## 3. What is Better vs Old API

| Feature | Old API | Proposed New API | Impact |
|---|---|---|---|
| **CLI Definition** | External `CliValue` variables, `ctx(val)` calls | Fluent inline `cli.opt*`, typed `ctx.int('name')` | **50% less boilerplate**, higher readability |
| **Subcommands** | Manual nesting / custom arg parsing | First-class `cli.command('name', (sub) => ...)` | Standardized CLI routing |
| **Spinners** | Static title only | Full runtime `.text`, `.step`, `.done`, `.failed`, `.skip()` | Dynamic, informative feedback |
| **Progress Bars** | Manual `tick()` / `close()` coordination | Polymorphic `Console.progress(...)` for batches, tasks, loops | Zero resource leaks, unified interface |
| **Multi Selection** | Inconsistent naming (`multiChoose`) | Clean `Console.multi(...)` | Shorter, intuitive, matches `choose` |
| **Theming** | Verbose custom builder functions | Out-of-the-box presets + `.copyWith()` + `.withTask()` | Instant styling without boilerplate |

---

## 4. Trade-Offs & Migration Strategy

### Trade-Offs:
- **String Keys in Context Access**: Using `ctx.int('port')` introduces string-key lookups compared to variable references (`ctx(port)`).
  - *Mitigation*: Both forms are fully supported. Users who prefer compile-time variable binding can still use `ctx(port)`, while the new `ctx.int('port')` is available for rapid scripting.
- **Dynamic Controller Callbacks**: The callback in `Console.spinner((spin) => ...)` creates a lightweight controller object.
  - *Mitigation*: Zero allocation overhead when using the simple `Console.spinner('Title', () => work)` signature.

### Backward Compatibility:
- All legacy methods (`Option.of`, `Arg.of`, `task.show()`, `batch.show()`, `Console.bar()`, `Console.ask()`) remain fully supported and functional.
