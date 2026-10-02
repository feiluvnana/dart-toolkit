---
name: optimize
description: Thoroughly audit and optimize dart-toolkit in every aspect (performance first, then bloat, API brevity, docs, consistency, bugs, platform parity) in three gated rounds. Use when the user types /optimize or asks for a full optimization or audit pass of the library. Module names after the command limit the scope, e.g. "/optimize http formats"; "--auto" runs without checkpoints.
---

# /optimize

A three-round audit → fix → verify pass over dart-toolkit. You are the **lead**: you spawn
read-only audit subagents, apply the accepted fixes yourself, and gate every round on the
release checks. Where this skill and `CONVENTIONS.md` disagree, `CONVENTIONS.md` wins.

> The Claude Code copy (`.claude/skills/optimize/SKILL.md`) is the same skill apart from **Arguments** and **Tools**. Change both together.

**Arguments** (typed after `/optimize`): module names limit the scope (with none, every module is audited); `--auto` skips the checkpoints (§0).

## Tools

| Need | Use |
|---|---|
| Subagent | `invoke_subagent`. Launch every subagent of one step in **one parallel call**. If no subagent tool exists, do each step yourself, one after another, without skipping the verify step. |
| Code search | `git grep -n` / `grep_search` before any read |
| Reading code | `view_file` with a line range (≤80 lines) |
| Edits | `replace_file_content` / `multi_replace_file_content` |

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
   native. Each prompt gives the dimension's *look for* text, the group's files, the §0 priority
   bar, the item format below, the skip list, and these limits: read-only; `git grep` before
   reading; at most 10 items, High/Medium only, each citing a `path:line` range it opened
   itself; reply exactly `NO_ACTIONABLE_ITEMS` if nothing clears the bar.

   ```markdown
   - **[TAG] Title** (`lib/src/x/y.dart:12-34`), High | Medium
     - Problem: 1–2 sentences.  - Fix: minimal diff, or "delete X; callers use Y".
     - Effect: measured or expected speedup, or call-site tokens saved/added.  - Blast radius: files (from `git grep`).
   ```
2. **Dedupe** by file + normalized title.
3. **Verify.** Spawn two skeptics per finding, all at once. Each defaults to *reject* when
   unsure:
   - *real*: open the cited lines and the blast radius. Is it true of the current code, and does
     the fix work without breaking callers?
   - *bar*: does it clear §0? Reject speculative features, churn without a measured or
     call-site gain, and anything that already exists under another name.
   Keep a finding only if **both** uphold it. Record the rest as `REJECTED (<lens>): <title>: <reason>`.
4. ⏸ **Checkpoint (after every audit pass):** show a table of the confirmed findings, numbered
   and ranked (tag, title, `path:line`, effect, files touched), the items you would accept
   under the gate's cap, and the rejected findings with reasons. Implement only what the user
   approves.
5. **Repeat** each round on HEAD after its gate, with the grown skip list, until a pass confirms
   nothing new or applies nothing. Round 1 runs at most 3 passes, Round 2 at most 2, and Round 3
   once.

## 4. Round 1: Foundation (4 dimensions)

| Tag | Look for |
|---|---|
| `PERF` | extra copies across the FFI boundary; `tk_alloc`/`tk_free` pairing on error paths; per-element allocation or record churn in hot loops and parsers; isolate closures capturing large outer state; missing cleanup on cancel. Say how to measure it. |
| `BLOAT` | extensions on `String/List/Map/int` used by one module only; duplicate helpers; aliases (two spellings of one operation); dead code; test-only seams; duplicate `bin/` examples. Every item deletes something. |
| `FEAT` | capabilities a script genuinely needs that are missing (`git grep` first: XPath, JSONPath, CSS `$`, streaming download and all HTTP verbs exist); verbose signatures; public classes missing Dart 3 modifiers (`final`/`sealed`/`interface`). |
| `DOC` | README/GUIDE/CONVENTIONS/CHANGELOG snippets and public dartdoc that don't compile against the current API or describe old behaviour; self-contradicting rules; POSIX-only assumptions; `is`/`case` checks on extension types (`Path`, `Row`, `Elements`, `Nodes`), which match raw `String`/`Map`/`List` after erasure. |

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

| Tag | Look for |
|---|---|
| `DISC` | workflows reachable only by knowing a top-level function exists; entry points missing from their facade (`Http`, `Path`, `Shell`, `Hash`, `Console`, …) where adding them doesn't lengthen the common call. Short globals such as `run(...)` stay. |
| `CONS` | naming drift between sibling APIs (`ConsoleTheme`/`TuiTheme` fields, HTTP verbs vs `Client` methods); parameter order across related functions; `null` vs throw vs `Either` for the same kind of failure; `_ =>` wildcards over sealed types. |

## 7. Gate 2: Harmonize

Follow Gate 1 steps 1, 5, 6 and 7, committing each item as `refactor: …`. In addition:

- After a rename, `git grep` the old name across the repo (`*.md` and dartdoc included). Zero
  hits may remain outside `CHANGELOG.md`.
- Run **smoke** after every `cli`/`tui` item.
- Close with `chore(gate-2): audit record`, then the step 7 checkpoint. On *go*, push and
  `git tag -f checkpoint-gate2`.

## 8. Round 3: Hardening (2 dimensions, then fix and test)

| Tag | Look for → done when |
|---|---|
| `BUG` | **Cancellation & errors:** cancelling the scope during each async API in `async`, `http`, `process` and `chrome` leaves no timer, isolate, process or socket open; worker errors rethrow with the original stack; no leaks on error paths; edge inputs (empty, unicode, CRLF, huge) don't crash or mis-parse. Each fix gets a test that proves it. |
| `BUG` | **Platform parity:** POSIX (runnable here) covers the pipefail exit code, signal forwarding and CRLF input. Windows (not runnable on macOS) is checked with unit tests on the *built* command line and path logic: `cmd /d /c` for built-ins, refusal of unsafe `cmd` args, `\` separators, and atomic replace while a file is locked. Label anything not executed as `unverified-on-windows` in the commit body. |

Round 3 is an audit pass (§3, with its ⏸ checkpoint), then the fixes, each committed as
`fix: …`, then the Gate 1 step 7 ⏸ checkpoint before the push. Finish when **gate** passes
(apart from *known failures*), the tree is clean, and `master` is pushed.

## 9. Finish

Summarize in chat: the items applied per gate, the items rejected and why, the A/B deltas, and
anything left unverified. If context or time runs out mid-gate, commit what is green, push, and
say which round and gate to resume from (the audit-record commits and `checkpoint-*` tags
mark the place).
