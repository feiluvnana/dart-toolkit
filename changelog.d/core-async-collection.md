# core / async / collection

## Upgrading

| before | after |
|---|---|
| `Env.require('API_TOKEN')` | `Env.get('API_TOKEN')` (throws `StateError` naming the key when unset or empty) |
| `Env.get('PORT') ?? '8080'` | `Env.get('PORT', or: '8080')` |
| `Env.get('HOME')` as `String?` | `Env.getOrNull('HOME')` |
| `Env.remove(k)` / `Env.reset()` | `Env.set(k, '')`: an empty variable is unset for `get`, `getOrNull`, `has` and `parse` |
| `Env.hasOverrides` | none (it was a test seam) |
| `(await xs.parallelize(f)).rights` | `await xs.parallelize(f).rights` (also `.lefts`, `.unwrap()`) |
| `e.isLeft` / `e.isRight` | `e is Left` / `e is Right` |
| `e.fold(onL, onR)` | `switch (e) { Left(:final value) => …, Right(:final value) => … }` |
| `e.mapRight(f)` / `e.mapLeft(f)` | a `switch`, or `f(e.unwrap())` |
| `Either.tryCatch(f)` / `tryCatchSync(f)` | `try` / `catch` |
| `stream.delayBy(d)` | `throttle`, or `Http.scope(delay:)` to pace requests |
| `Mutex().run(f)` | `Semaphore(1).run(f)` |
| `(() => work()).isolate()` | `Isolate.run(() => work())` |
| `res.isolate((r) => …)` | `Isolate.run(() => …)` |
| `Sequence<T>.empty()` | `const <T>[].sequence` |
| `seq.none(test)` | `!seq.any(test)` |
| `seq.whereNot(test)` | `seq.where((e) => !test(e))` |
| `seq.interleave`, `scan`, `cartesian` | a `for` loop / two-`for` collection literal |
| `seq.shuffled()` | `seq.toList()..shuffle()` |
| `seq.groupJoin(other, …)` | `groupBy` + `indexBy`, or `leftJoin` |
| `pairs.inverted` / `pairs.unzip` | `pairs.map((p) => (p.$2, p.$1))` / `(pairs.keys.toList(), pairs.values.toList())` |
| `sorted.thenWith(cmp)` | `sorted.thenBy(key)` (`sortedWith` stays for a custom comparator) |
| `seq.minMax(key)` | `seq.minBy(key)` and `seq.maxBy(key)` |
| `t.numbers('bytes').sequence.sum` | `t.numbers('bytes').sum` (`Table.numbers` returns `Sequence<num>`) |

## Removed

- `Either.isLeft`, `isRight`, `fold`, `mapLeft`, `mapRight`, `Either.tryCatch`, `tryCatchSync`.
- `Stream.delayBy`, `Mutex`, `FunctionIsolateExtensions.isolate()`, `Response.isolate`.
- `Env.require`, `Env.remove`, `Env.reset`, `Env.hasOverrides`.
- `Sequence.empty`, `none`, `whereNot`, `interleave`, `scan`, `cartesian`, `shuffled`, `groupJoin`,
  the pair extensions `inverted` and `unzip`, and `Sorted.thenWith`. `Sequence.minMax` is now private.

## Added

- `Env.get(key, or:)` throws when the key is missing and no `or` is given. `Env.getOrNull(key)` is the nullable form.
  An empty variable counts as unset everywhere in `Env`, including `parse`/`load` without `override`.
- `rights`, `lefts` and `unwrap()` on `Future<List<Either>>`, so `await files.parallelize(f).rights` needs no parentheses.
- `Row.get<DateTime>` / `getOrNull<DateTime>` read ISO 8601 text (F-11).
- `Table.numbers` returns `Sequence<num>`.

## Fixed

- ASYNC-2 remainder: `chunkEvery` now emits the batch it holds before passing on an error. `throttle(trailing:)`
  was already fixed in phase 2 (it has an `onError` flush), and its test still passes.

## Faster

A/B is the phase-2 tree against this branch, run back to back in alternating order. Each figure is the
median of 6 process runs, and each run takes the median of 9 in-process repeats (JIT).

- P-COLL-1: `Sequence` delegates `length`, `isEmpty`, `isNotEmpty`, `last`, `elementAt` and `toList` to its source.
  `Sorted`'s deferred list also forwards `toList`. For 1M ints, `.sequence.map(f).toList()` went 9 → 6 ms
  and `.sequence.map(f).length` 3 → 0 ms.
- P-COLL-2: rows that a table just built (`select`, `rename`, `derive`, `join`/`leftJoin`, `pivot`,
  the group folds) are frozen by `UnmodifiableMapView` instead of being copied by `Map.unmodifiable`.
  On 200k rows, `select` went 72 → 38 ms and `derive` 72 → 45 ms. They are still immutable, and the test now
  covers join, pivot and the group folds too.

## Skipped

- **P-COLL-3** (`num.tryParse` first, drop the regex). The current `_coerce` already runs the regex only on text
  that contains a comma, and it already rejects non-finite values (so COLL-8, `get<int>('1e400')`, already
  returns `null`/throws `StateError`; there is a test for it now). I wrote a hand-rolled comma scanner and measured
  it against the current code on 300k cells: 20 vs 20 ms when half the cells are grouped, and 18.5 vs 20 ms on plain
  cells. It was not faster, so I reverted it.
- **`Io.stripAnsi` / `Io.width` / `Io.truncate` → private.** `Io.width` and `Io.truncate` are used by
  `cli/console.dart` and `Table.show` (`collection`). Those are separate libraries, so a private name cannot reach
  them. `Io.stripAnsi` is used by 11 assertions in `cli_test`. All three stay public.
- **F-11, "date columns sort as dates".** Detecting dates means calling `DateTime.tryParse` (regex-based) on every
  text cell of every sort key, which is too expensive for every sort. ISO 8601 text in one format already sorts
  chronologically as text, and `DateTime` cell values already compare as dates. Only `Row.get<DateTime>` was added.
  `JsonDocument.to<DateTime>` is in `formats` and is not done here.
- **F-8 `parallelize(show:)`.** `core` holds only the data interfaces (`TaskProgress`, `BatchProgress`) and
  `IoBridge`, whose hooks are `above`/`suspend`. It has no renderer hook. A bar would need a new
  `IoBridge` progress seam that `cli` installs. That means a new public seam plus a change in `cli`, which is outside
  this area. The alternative, importing `cli` into `async`, is ruled out.

## CONVENTIONS suggestions

- §1 "A guaranteed value is not nullable": add `Env.get` / `Env.getOrNull` as an example. Why: `Env.get` was the
  last bare-name getter that returned `String?`.
- §1 (new line under "One word per idea"): "an empty environment variable is unset". Why: `has` already meant
  non-empty while `get` returned `''`, and `require` treated `''` as missing. These were three rules for one idea.
