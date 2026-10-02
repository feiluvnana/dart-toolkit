---
name: optimize
description: Thoroughly audit and optimize dart-toolkit in every aspect (performance first, then bloat, API brevity, docs, consistency, bugs, platform parity) in three gated rounds. Use when the user types /optimize or asks for a full optimization or audit pass of the library. Module names after the command limit the scope, e.g. "/optimize http formats"; "--auto" runs without checkpoints.
---

# /optimize

A three-round audit → fix → verify pass over dart-toolkit. You are the **lead**: you spawn
read-only audit subagents, apply the accepted fixes yourself, and gate every round on the
release checks. Where this skill and `CONVENTIONS.md` disagree, `CONVENTIONS.md` wins.

> The Antigravity copy (`.agents/skills/optimize/SKILL.md`) is the same skill apart from **Arguments** and **Tools**. Change both together.

**Arguments** (`$ARGUMENTS`): module names limit the scope (with none, every module is audited); `--auto` skips the checkpoints (§0).

## Tools

| Need | Use |
|---|---|
| Subagent | `Agent` with `subagent_type: "Explore"` (read-only). Launch every agent of one step in **one message** so they run concurrently. |
| Code search | `git grep -n` / Grep before any Read |
| Reading code | `Read` with `offset`/`limit` (≤80 lines) |
| Edits | `Edit` |

Only the lead edits. Subagents never edit files, run git, or write reports to disk: their final
message is the report. Never read a whole file when a line range will do.

## 0. Ground rules

| Rule | What it means |
|---|---|
| **Checkpoints** | Unless `--auto` was passed, **stop and wait for the user** after every step marked ⏸: show the checkpoint report, then end your turn. Continue only on the user's reply: *go*; *drop* / *add* items; *redo* with a note; or *stop*. The user may add items rejected earlier: they override a skeptic's verdict. With `--auto`, print the same report and carry on. Step 0's "tree not clean" stop applies in both modes. |
| **Priority** | `CONVENTIONS.md` order: **speed > call-site brevity > everything else**. Speed means measured startup, throughput or memory (§1.1). A shorter spelling that costs measurable time loses. Pruning counts as brevity. An addition must delete more at call sites than it adds to the surface, and must cost no measurable startup. Speculative features are rejected. |
| **Clean cuts** | No `@Deprecated`, shims or aliases. A rename or removal updates every call site in `lib/ bin/ tool/ test/` and every doc in the same commit. |
| **Reports stay in chat** | No `AUDIT_*.md` or other report files. The decision record (accepted, and rejected with reasons) goes into the gate's commit body, changes go into `CHANGELOG.md` (Unreleased), and new rules go into `CONVENTIONS.md` with their *why*. |
| **`bin/` is examples** | Smoke-test `bin/*.dart`; delete or merge duplicates freely. |
| **One item, one commit** | Apply one accepted item (or one tightly coupled micro-batch), verify, commit locally. A rollback only ever touches the uncommitted item. |
| **Commit & push** | Push at the end of each gate. Author `feiluvnana`, no `Co-Authored-By` trailer. Never bump the `pubspec.yaml` version or move CHANGELOG `Unreleased`: the owner picks the version. |
| **Co-worker** | Another agent may push to `master`. Before each gate and each push, run `git fetch && git status`; if `origin/master` moved, rebase and re-run the gate. Never `reset --hard` or force-push. |
| **History** | Titles rejected in earlier runs form the **skip list**: `git log --grep='audit record' --format=%b \| grep '^REJECTED' \| sed 's/^REJECTED[^:]*: //'`. Add this run's rejections as you go. |

## 1. Verification

| Name | Command | When |
|---|---|---|
| **fast** | `dart analyze --fatal-infos && dart test test/<module>_test.dart` | after every item |
| **gate** | `make check test` (analyze, format check, full suite) + **smoke** | end of each gate |
| **smoke** | `for b in tk books keybox; do dart run bin/$b.dart --help >/dev/null \|\| echo FAIL $b; done` | gate, and after any `cli`/`tui` item |
| **native** | `cargo check --manifest-path native/Cargo.toml && make native && dart test test/native_test.dart test/hash_test.dart test/archive_test.dart` | any `native/src/` change |
| **startup A/B** | §1.1 | any `lib/` change that adds an import or top-level initializer |

Each module has `test/<module>_test.dart`, plus `archive_test` and `native_test`. A `formats`
change also runs `test/formats_diff_test.dart`.

### 1.1 Startup A/B (never a standalone number)

Single-run startup drifts by ±80 ms, so a one-off `make bench` proves nothing. Compare it
back to back against the last checkpoint:

```bash
git worktree add -f ../tk-base checkpoint-<prev> && (cd ../tk-base && dart pub get >/dev/null)
for i in 1 2; do (cd ../tk-base && dart run tool/bench.dart <modules> -r 8); dart run tool/bench.dart <modules> -r 8; done
git worktree remove --force ../tk-base
```

Read the **min-over-bare** column. A module regresses if HEAD is more than 10 ms worse than the
base in both pairs. Quote deltas as `base → head`. A throughput change needs its own
microbenchmark (MB/s or ms/op, base vs head in the same run) in the commit body. Under 5 % gain
plus more code means **reject**.

### 1.2 Two-strike rollback

When an item fails **fast**, make one corrective attempt. If it still fails, discard only that
item (`git restore --staged --worktree -- . && git clean -fd -- lib bin tool test native`; this
is safe because every earlier item is committed). Record it as
`REJECTED (compile|test): <title>: <reason>` and move on. Never leave a red tree between items.

### 1.3 Native ABI lockstep

Changing an `extern "C"` signature bumps both `tk_version()` in `native/src/lib.rs` and
`NativeLib._abi` in `lib/src/native/native.dart`. `native/prebuilt/` is gitignored, so run
`make native` for the host before testing, and add a CHANGELOG line saying the release must run
`make native-all`.

## 2. Step 0: Baseline

1. `git fetch && git status`: the tree must be clean and `master` must equal `origin/master`.
   Otherwise stop and ask.
2. Run **gate**. Record any failing test names verbatim as the *known failures*. A later gate
   passes if it fails on no other test. A failing analyze or format check gets fixed first, as
   its own commit.
3. If `native/prebuilt/<host>/` is missing or older than `native/src/`, run **native**.
4. `git tag -f checkpoint-step0` (local only; tags are never pushed).
5. ⏸ **Checkpoint:** show the scope, the known failures, and any baseline fix commits.

## 3. One audit round

1. **Find.** Spawn one finder per *dimension × module group*, all at once. Groups:
   `foundation` = core, collection, async, process, native, hash; `data` = formats, fs, http;
   `surface` = cli, tui, chrome, `bin/`. Drop out-of-scope modules and empty groups. A module's
   files are `lib/<m>.dart`, `lib/src/<m>/` and `test/<m>_test.dart`, plus `native/src/*.rs` for
   native. Each prompt gives the dimension's whole block (§4, §6, §8), the group's files, the §0
   priority bar, the item format below, the skip list, and these limits: read-only; `git grep` before
   reading; at most 10 items, High/Medium only, each citing a `path:line` range it opened
   itself; reply exactly `NO_ACTIONABLE_ITEMS` if nothing clears the bar.

   ```markdown
   - **[TAG] Title** (`lib/src/x/y.dart:12-34`), High | Medium
     - Problem: 1–2 sentences.  - Fix: minimal diff, or "delete X; callers use Y".
     - Evidence: what the dimension's **Evidence** asks for.  - Blast radius: files (from `git grep`).
   ```
2. **Dedupe** by file + normalized title.
3. **Verify.** Spawn two skeptics per finding, all at once. Each defaults to *reject* when
   unsure:
   - *real*: open the cited lines and the blast radius. Is it true of the current code, and does
     the fix work without breaking callers?
   - *bar*: does it clear §0, carry the dimension's **Evidence**, and avoid its **Not a finding**
     list? Reject speculative features, churn without a measured or call-site gain, and anything
     that already exists under another name.
   Keep a finding only if **both** uphold it. Record the rest as `REJECTED (<lens>): <title>: <reason>`.
4. ⏸ **Checkpoint (after every audit pass):** show a table of the confirmed findings, numbered
   and ranked (tag, title, `path:line`, effect, files touched), the items you would accept
   under the gate's cap, and the rejected findings with reasons. Implement only what the user
   approves.
5. **Repeat** each round on HEAD after its gate, with the grown skip list, until a pass confirms
   nothing new or applies nothing. Round 1 runs at most 3 passes, Round 2 at most 2, and Round 3
   once.

## 4. Round 1: Foundation (4 dimensions)

Every dimension block below has the same four parts, and a finder's prompt carries the whole
block. **Hunt** is where to look. **Evidence** is what an item must show to be kept. **Not a
finding** is what the *bar* skeptic rejects on sight. **Fix** is what the change looks like.

### `PERF`: speed (startup, throughput, memory)

**Hunt**
- *Startup:* a new `import` in `lib/<m>.dart` that serves one method (CONVENTIONS §5: `Table.read`, not
  `Path.table()`); a computing top-level `final` (a `RegExp`, lookup table or map built at load
  rather than on first use); a third-party runtime dependency other than `path`.
- *Hot loops* (tokenizers in `formats`, the CSS/XPath engines, `Table`/`Sequence` operators, body
  decoding in `http`, Console redraw): per-element `substring`/`sublist`/spread/closure allocation,
  a record returned per token, a `RegExp` built inside the loop, string `+` in place of a
  `StringBuffer`, a `toList()` in the middle of a lazy chain, the same bytes `utf8`-decoded twice,
  `dynamic` dispatch on a typed path.
- *Algorithmic:* a full sort to read `take(n)`, `length` or `isEmpty`; a linear scan repeated
  inside a loop (O(n²)) where a set or map is available; recursion that a stack walk would beat
  (CONVENTIONS §4 depth rule).
- *Isolates:* a closure for `Isolate.run`/`Pool` built inside a method, which captures `this`; a whole
  input sent where one slice would do; an isolate spawned per item instead of per worker.
- *FFI:* bytes copied into native memory when a path would do (files are read by the library);
  `tk_alloc` without `tk_free` on the throw path; a "buffer full, call again" loop that does not grow
  geometrically.
- *I/O:* a whole file or body read where a stream would do; a fresh client per request, which
  defeats keep-alive; sequential `await` in a loop where `parallelize`/`Pool` fits; an unbounded
  cache or map.

**Evidence:** the measurement that would prove it. For a startup claim, `tool/bench.dart <module>`
(§1.1). For throughput, a microbenchmark sketch: the input and its size, the operation, the
expected MB/s or ms/op. An *expected* gain names its mechanism ("one allocation per token
removed", "O(n log n) → O(n)"), never just "faster".

**Not a finding:** under a 5 % gain; a cold path (option parsing, help rendering, one-shot
setup) unless it runs at startup; sprinkling `const` or `final`; code in `bin/` or `test/`; a gain
that needs a third-party package or native assets (`hook/build.dart`).

**Fix:** the smallest diff that removes the cost. Commit as `perf: …` with `base → head` numbers
in the body.

### `BLOAT`: surface and code that earn nothing

**Hunt**
- *Aliases:* two spellings of one operation, or a method that only composes two others with no
  call-site saving (CONVENTIONS §1 "One name per operation").
- *Extensions on `String`/`Iterable`/`Map`/`int`* beyond the conversion getter (`.url`, `.path`,
  `.json`, `60.s`). The vocabulary belongs on the returned type.
- *Public but not API:* `git grep -wn Name -- lib bin test '*.md'` finds only the defining file and
  tests. Such a symbol goes private, or goes. This includes test-only seams: a parameter,
  constructor or `@visibleForTesting` that exists for injection.
- *Dead code:* unused private members, branches unreachable after an exhaustive `switch`, a
  parameter every caller passes the same value, flags left over from a removed feature.
- *Duplicate helpers:* the same escape, quote, byte-format or path join written in two modules.
  Keep one, in `core` only if that adds no import.
- *Prose:* a doc comment that restates its signature; two `bin/` examples showing one idea.

**Evidence:** the `git grep` hit counts (lib / bin / test / docs) for each symbol removed, and the
net lines deleted. Name the replacement callers will use.

**Not a finding:** anything CONVENTIONS keeps on purpose (`Element.attr`, `Sequence.union`,
`chunk`, Chrome's `frame`/`pdf`/dialogs, `Duration.jittered`); a deletion that makes a common
call longer; "unused in `bin/`" alone, because the bar is usefulness to script authors, not `bin/`
usage.

**Fix:** delete, and update every call site and doc in the same commit. Commit as `refactor: …`,
with a CHANGELOG *Removed* line naming the replacement.

### `FEAT`: shorter call sites and missing capabilities

**Hunt**
- *Long call sites:* places in `bin/`, README, GUIDE or tests that spend 3+ lines on a common
  script task: a status check, a manual loop over pages, a parse-then-null-check.
- *Verbose signatures:* a required argument with an obvious default; help text not in the 2nd
  positional; a nullable return where callers write `!` (`git grep -n ')!'`). CONVENTIONS says to
  return the guaranteed value and add `…OrNull`.
- *Grid holes:* an operation present on one member of a family and missing on its siblings
  (`String`/`List<int>`/`Path`; `Opt`/`Arg`; `ConsoleTheme`/`TuiTheme`).
- *Modifiers:* a public class with no `final`/`base`/`interface`/`sealed`, or a closed set of
  variants that is not `sealed`, so `switch` can't be exhaustive.
- *Missing capability:* only one a real script hits. `git grep` before proposing it: XPath `$x`,
  CSS `$`, JSONPath, streaming `download`, every HTTP verb, `parallelize`, `retry` and `Table`
  already exist.

**Evidence:** the call site before and after, with tokens saved, plus the list of existing call
sites that shrink. An addition must delete more at call sites than it adds to the surface (§0).

**Not a finding:** a capability no call site needs today; anything that already exists under
another name (that would be an alias, so `BLOAT`); cryptography beyond hashing; anything that adds
a runtime dependency or measurable startup; a builder where order means nothing.

**Fix:** the smallest API that removes the long spelling, with the Gate 1 Batch C tests. Commit as
`feat: …`.

### `DOC`: docs that disagree with code

**Hunt**
- *Stale snippets:* every identifier in a README, GUIDE, CHANGELOG *Unreleased* or `///` example
  checked with `git grep -w`. Renamed or removed names, old argument shapes.
- *Wrong behaviour:* documented defaults, throw-vs-null, exit codes (64 / 1 / 128+n) and caps
  (robots.txt 512 KiB, sitemap 50 MB, depth 1000, archive 200× / 1 GiB) that differ from the code.
- *CONVENTIONS* rules the code breaks, rules that contradict each other, or a rule with no *why*.
- *Dartdoc:* a comment that restates the signature (delete it), or one that omits what the
  signature can't say: what it throws, which scope it reads, how it cancels.
- *POSIX-only assumptions:* `/` joins, `~`, `sh -c` in docs or code.
- *Extension-type tests:* `is`/`case` checks on `Path`, `Row`, `Elements` or `Nodes`, which match
  the raw `String`/`Map`/`List` after erasure.

**Evidence:** the doc line and the code line that disagree, both cited.

**Not a finding:** wording polish that keeps the meaning; docs for private API; a longer
explanation where a table row already says it.

**Fix:** a deletion goes in Batch A, a correction in Batch C. If the code is wrong rather than
the doc, record it as a `BUG` for Round 3.

## 5. Gate 1: Apply

1. **Triage.** Open every confirmed finding's lines yourself, since subagents misread code.
   Drop anything that breaks a `CONVENTIONS.md` rule. Rank measured `PERF` first, then
   `BLOAT`, then the rest, and cap at **15** items.
2. **Batch A: deletions** (`BLOAT`, doc deletions). Commit each as `refactor: …`.
3. **Batch B: perf** (`PERF`). Run **native** and §1.3 if Rust changes, and **startup A/B** if
   imports change. Commit each as `perf: …` with the numbers in the body.
4. **Batch C: additions** (`FEAT`, `DOC` fixes). Test each new API for the cases that apply:
   happy path; edge (empty, boundary, unicode); failure (the exception or `Left` it documents);
   cancellation under `Cancel.scope` if it is async; differential against the reference if it
   replaces an engine (see `formats_diff_test.dart`). Commit each as `feat: …`.
5. **Docs move with code.** A public API change updates `README.md`, `GUIDE.md`, `CHANGELOG.md`
   (Unreleased, one row or bullet) and, for a new rule, `CONVENTIONS.md`, all in the same
   commit.
6. **Close.** Run **gate**, then **startup A/B** on every module touched. Then run
   `git commit --allow-empty -m "chore(gate-1): audit record"` with the accepted and
   `REJECTED …` lines in its body.
7. ⏸ **Checkpoint (after every implementation pass):** show the commits (`git log --oneline
   checkpoint-<prev>..`), the items rejected by rollback, the gate results, and the A/B deltas.
   On *go*, push, `git tag -f checkpoint-gate1`, and start the next audit pass. On *revert N*,
   revert that commit, re-run **gate**, and show the checkpoint again.

## 6. Round 2: Consistency (2 dimensions, on HEAD after Gate 1)

Same four parts as §4.

### `DISC`: can a script author find it?

**Hunt**
- Work through each entry point as autocomplete shows it: `'…'.url.`, `'…'.path.`, `.json.`,
  `Http.`, `Shell.`, `Hash.`, `Console.`, `Cancel.`. List the workflows that are reachable only by
  already knowing a top-level function or class name.
- A facade missing a member its siblings have; a returned type missing a method that exists only
  as a top-level function taking that type.
- A README tour step with no visible way in from the previous step's result.

**Evidence:** the path a user takes today (what they must already know) beside the path after
the fix. The common call must not get longer.

**Not a finding:** short globals that are the point (`run(...)`, `ask`, `confirm`); a second door
to the same operation (an alias, so `BLOAT`) unless the situation picks the door (CONVENTIONS §1).

**Fix:** *move* the entry point, never duplicate it. A clean cut, with every call site updated.

### `CONS`: siblings that read alike

**Hunt**
- Drift from CONVENTIONS §1's *One word per idea* table: `or`, `text`/`bytes`/`form`/`json`,
  `markup`, `download`, `…OrNull`, `.many()`, `links`.
- Names: booleans not `is…`; a sync twin not ending in `Sync`; a pure function of the receiver
  written as a method instead of a getter; `on<event>`/`<event>` pairs broken; theme fields named
  differently in `ConsoleTheme` and `TuiTheme`; HTTP verbs vs `Client` methods.
- Shape: parameter order across related functions; a builder step that doesn't return the
  receiver; a registration that doesn't return its unregistration.
- Failure: `null` vs throw vs `Either` for the same kind of failure; an error message missing the
  name of what was absent; `_ =>` wildcards over sealed types.

**Evidence:** the two sites side by side, each cited, and the CONVENTIONS rule they split on.

**Not a finding:** a difference a CONVENTIONS rule allows (two doors chosen by situation, `Table`
keyed by column name, the two `Object` parameters on `ctx.follow` and `client.scrape`).

**Fix:** rename every site; Gate 2's zero-hit `git grep` applies.

## 7. Gate 2: Harmonize

Follow Gate 1 steps 1, 5, 6 and 7, committing each item as `refactor: …`. In addition:

- After a rename, `git grep` the old name across the repo (`*.md` and dartdoc included). Zero
  hits may remain outside `CHANGELOG.md`.
- Run **smoke** after every `cli`/`tui` item.
- Close with `chore(gate-2): audit record`, then the step 7 checkpoint. On *go*, push and
  `git tag -f checkpoint-gate2`.

## 8. Round 3: Hardening (2 dimensions, then fix and test)

Same four parts as §4. Both lenses tag their items `BUG`. Every item must come with a
reproducible scenario; a "could happen" with no input or schedule is rejected.

### `BUG`: cancellation, errors and edge inputs

**Hunt**
- *Cancel:* cancel `Cancel.scope` during each async API in `async`, `http`, `process` and `chrome`
  (`retry` backoff, `Pool` queue, `delay`, lock waiters, `download` mid-body, `run` with children).
  Afterwards no `Timer`, `StreamSubscription`, isolate, child process or socket may remain open,
  and pool permits must be returned.
- *Errors:* a worker error rethrown without its original stack (`Error.throwWithStackTrace`); a
  `catch` that swallows; a `Completer` completed twice; cleanup skipped on the error path; a
  `finally` that awaits after the scope is gone.
- *Edge inputs:* empty, a single element, multi-byte UTF-8 split across a chunk boundary, BOM, CRLF,
  non-UTF-8, exactly the 4 MiB native threshold, nesting at depth 1000, an unterminated construct
  (must be a `FormatException`, never a hang), lengths beyond `i32`.

**Evidence:** a test sketch: input or schedule → observed wrong output, hang or leak → expected.

**Not a finding:** a theoretical race with no schedule that triggers it; "could be null" where the
type says otherwise; behaviour CONVENTIONS §4 already defines.

**Fix:** the fix plus the test that failed before it.

### `BUG`: platform parity

**Hunt**
- *POSIX* (runnable here): the pipefail exit code, signal forwarding to the process tree, CRLF
  input, `/dev/tty` restore on every exit path.
- *Windows* (not runnable on macOS): unit tests on the *built* command line and path logic:
  `cmd /d /c` for built-ins, refusal of unsafe `cmd` arguments, `\` separators and drive roots,
  atomic replace while a file is locked, native prebuilt lookup by `<os>_<arch>`.

**Evidence:** the command line or path the code builds, beside the one the platform needs.

**Not a finding:** a platform the package doesn't target; behaviour that differs by design and is
documented.

**Fix:** the fix plus a unit test. Label anything not executed as `unverified-on-windows` in the
commit body.

Round 3 is an audit pass (§3, with its ⏸ checkpoint), then the fixes, each committed as
`fix: …`, then the Gate 1 step 7 ⏸ checkpoint before the push. Finish when **gate** passes
(apart from *known failures*), the tree is clean, and `master` is pushed.

## 9. Finish

Summarize in chat: the items applied per gate, the items rejected and why, the A/B deltas, and
anything left unverified. If context or time runs out mid-gate, commit what is green, push, and
say which round and gate to resume from (the audit-record commits and `checkpoint-*` tags
mark the place).
