# Guide to API Auditing, Ergonomics Testing & Bug Hunting

> A battle-tested methodology for discovering API clutter, awkward naming conventions, architectural defects, and hidden concurrency bugs in Dart developer tools.

---

## 1. The Core Philosophy: Why Unit Tests Miss API Friction

Automated unit tests ensure that code behaves according to the author's internal assumptions. However, **unit tests rarely catch bad developer experience (DX)**:
- The author already knows which hidden type conversions to make.
- Tests often mock dependencies or construct private/internal objects directly.
- Tests focus on isolated happy paths rather than end-to-end user workflows.
- As a result, critical deadlocks, state leaks, clumsy boilerplate, and weird naming pass CI with 100% green checkmarks.

To design an exceptional developer tool (like `dart-toolkit`), you must evaluate the library from the **outside-in**, treating the public API surface as a user interface.

---

## 2. The 4-Step Script-Driven Discovery Methodology

When auditing an API, use this empirical 4-step framework:

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│ 1. Realistic    │ ──> │ 2. Write from   │ ──> │ 3. Friction &   │ ──> │ 4. Ergonomic    │
│    Usecase      │     │    Blank File   │     │    Pain Logging │     │    Root-Cause   │
└─────────────────┘     └─────────────────┘     └─────────────────┘     └─────────────────┘
```

### Step 1: Define a Concrete, Real-World Use Case
Do not test individual methods in isolation. Formulate a realistic script that a developer would write in production:
- *Example*: "Crawl an e-commerce catalog, login via an HTML `<form>`, follow pagination links with metadata, extract prices from the DOM, and save results to an atomic CSV file."
- *Example*: "Read a multi-format config (`.env` + `pubspec.yaml`), spawn a worker pool with a rate limiter, track progress with a terminal UI, and handle Ctrl-C shutdown gracefully."

### Step 2: Write the Script from an Empty File
Start from a clean slate. Import only the public root package:
```dart
import 'package:dart_toolkit/dart_toolkit.dart';
```
Write the script relying **only on IDE autocompletion (`.` dot suggestions) and hover docs**. Do not look at the source code implementation.

### Step 3: Actively Log Hesitations and Papercuts
Every time you experience friction while typing, write it down immediately:
- **Did autocomplete fail to suggest what you wanted?** (e.g. typing `res.` didn't suggest `.form()`).
- **Did you have to cast or re-wrap an object?** (e.g. `entry.path` returned `String`, so you had to write `Path(entry.path)`).
- **Did you have to write clumsy record/tuple syntax?** (e.g. `meta: [('page', 1)]` instead of `meta: {'page': 1}`).
- **Did you have to do multiple method calls for a one-liner task?** (e.g. `res.parse(.html).form('#login')!.at(res.url)`).
- **Did the API silently return empty data instead of an error?** (e.g. `res.bytes` returning `[]` on streaming responses).

### Step 4: Trace Root Causes & Modernize
Ask: *What is the ideal 1-line expression the user actually wants to write?*
Refactor the API so that the intuitive line is the canonical line.

---

## 3. How to Find Hidden Bugs & Concurrency Deadlocks

### 3.1 The "Resource Lifecycle & Asymmetry" Check
Search for any operation that takes or acquires a resource:
- Does it have a matching `release()`?
- Is that release inside a `finally` block?
- **Example Bug Found**: In `Fetcher.send()`, `await limiter?.take();` was called. But neither `Fetcher` nor `Waiting` ever called `release()`! When users passed a `Semaphore(5)` as their limiter, the client deadlocked forever after 5 requests.

### 3.2 The "Error Path Frontier Leak" Check
In stateful systems (like crawlers, queues, or pools):
- Trace what happens when a worker throws an exception (e.g. timeout, DNS error, 500 status, or parser crash).
- Does the in-flight tracker clean up the item?
- **Example Bug Found**: In `Crawler._worker`, `_inflight.remove(fetch)` was placed *after* `send(fetch)`. When `send()` threw an exception, `_inflight.remove(fetch)` was skipped, leaking failed requests into `pending` and permanently poisoning resume state files.

### 3.3 The "Asynchronous Teardown Gap" Check
When asynchronous methods fail:
- Does an error delivered to a stream controller trigger downstream teardowns *before* local `finally` blocks complete?
- **Example Bug Found**: In `Crawler.begin()`, an error in `_restoreFile()` notified the listener immediately. The test suite caught the error and deleted the temp folder while `_disarm()` was still running asynchronously in `finally`. Inside `_disarm()`, `file.delete()` crashed with an unhandled `PathNotFoundException` in the background zone.

### 3.4 Concurrency Boundary Stress Testing
Always test concurrency primitives with extreme parameters:
- `concurrency: 1`: Does it enforce strict serial execution?
  - *Bug Found*: In `StreamExtensions.parallelMap`, task addition happened after the pause check, launching 2 concurrent tasks even when `concurrency: 1` was configured.
- `concurrency: 100`: Does it hit file descriptor or socket pool exhaustion?
- Zero items / Empty inputs: Does it hang or finish immediately?

---

## 4. How to Spot "Weird Names" & Inconsistencies

### 4.1 The Grammar & Part-of-Speech Heuristic
- **Types and Classes must be Nouns**:
  - `ServerRequest`, `ServerResponse`, `FileSystemEntry`, `Progress`.
  - *Weird Name Found*: `Asked` and `Served` are past-participle verbs/adjectives used as types.
- **Mutating operations must be Verbs**:
  - `delete()`, `render()`, `writeText()`, `makeDir()`.
- **Pure copying / transform operations should be Adjectives or Participles**:
  - `sorted()`, `distinct()`, `normalized()`, `reversed()`.

### 4.2 Domain-Specific Vocabulary Alignment
Verify that terminology matches the domain standard:
- **JSON**: In JSON, values are `string`, `number`, `boolean`, `array`, `object`.
  - *Weird Name Found*: `doc.flag('active')`. In JSON, fields are booleans, not CLI flags. Calling it `flag()` is confusing.
- **Terminal Control**:
  - *Weird Name Found*: `Terminal.line()` erases the current line (`\x1B[2K`). Naming an erasing method `line()` sounds like it prints a line. It should be `clearLine()`.
- **Archives**:
  - *Inconsistency Found*: `FileSystemEntry.isDir` vs `ArchiveEntry.folder`. Standardize on `isDir`.

### 4.3 The "Semantic Divergence" Trap
Ensure identical method names have identical semantics across types:
- *Inconsistency Found*: `IterableExtensions.distinctBy` vs `StreamExtensions.distinctBy`.
  - On `Iterable`, `distinctBy` performs global deduplication across the entire collection.
  - On `Stream`, `distinctBy` only dropped consecutive duplicates (like Unix `uniq`).
  - Giving two methods the exact same name with completely different contracts is a dangerous trap.

### 4.4 Effective Dart Compliance Checklist
1. **No Async Getters**:
   - Getters must be fast and synchronous.
   - *Violation Found*: `Future<int> get dirSize` and `Future<bool> get isDirEmpty`. A getter should never perform recursive disk I/O or return a `Future`. Convert to methods: `dirSize()` and `isDirEmpty()`.
2. **Collection Emptiness Symmetry**:
   - Whenever `isEmpty` is provided, `isNotEmpty` must also be provided.
   - *Violation Found*: `Json` provided `isEmpty` but deliberately omitted `isNotEmpty`.
3. **Paths are `Path`**:
   - If `Path` is the library's core abstraction, return types must return `Path`, not raw `String`.
   - *Violation Found*: `FileSystemEntry.path` returned `String`, forcing repetitive `Path(entry.path)`.

---

## 5. Summary Checklist for Every API Feature

Before publishing or finalizing any module:

- [ ] **Can it be written in one fluid dot-expression?**
- [ ] **Does it require manual type casting (`as T`) or re-wrapping?**
- [ ] **If an exception is thrown, does any background timer, process, or permit leak?**
- [ ] **If given empty input, does it complete cleanly?**
- [ ] **Does it conform to standard Dart idioms (`Iterable`, `Stream`, `FutureOr`, `isNotEmpty`)?**
- [ ] **Are method names self-explanatory without reading the implementation?**
