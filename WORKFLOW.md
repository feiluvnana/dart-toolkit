# Multi-Agent Audit & Modernization Workflow

A three-round audit → fix → verify pipeline for one **Claude Code (Opus) lead session**. The lead
spawns read-only audit subagents, applies the accepted fixes itself, and gates every round on
the release checks. `CONVENTIONS.md` outranks this file; where they disagree, it wins.

---

## 0. Ground rules

| Rule | What it means |
|---|---|
| **Priority** | `CONVENTIONS.md` order: **call-site brevity > speed > everything else**. Pruning counts as brevity. An addition is accepted only if it deletes more at call sites than it adds to the surface. Speculative features are rejected. |
| **Clean cuts** | No `@Deprecated`, shims or aliases. A rename or removal updates every call site in `lib/ bin/ tool/ test/` and every doc in the same commit. |
| **Reports stay in chat** | Audit reports are subagent return values, never files. No `AUDIT_*.md`, no `.audits/`. The decision record (accepted + rejected-with-reason) goes into the gate's commit body; what changed goes into `CHANGELOG.md` (Unreleased); new rules go into `CONVENTIONS.md` with their *why*. |
| **`bin/` is examples** | `bin/*.dart` are usage examples, not product. Smoke-test them; delete or merge duplicates freely. |
| **One item, one commit** | Apply one accepted item (or one tightly coupled micro-batch), verify, commit locally. Rollback only ever touches the uncommitted item. |
| **Commit & push** | Push at the end of each gate. Author `feiluvnana`, no `Co-Authored-By` trailer. Never bump `pubspec.yaml` version or move CHANGELOG `Unreleased`: the owner picks the version. |
| **Co-worker** | Another agent may push to `master`. Before each gate and each push: `git fetch && git status`; if `origin/master` moved, rebase and re-run the gate. Never `reset --hard` or force-push. |

### Tool mapping (Claude Code)

| Need | Use |
|---|---|
| Read-only audit subagent | `Agent` with `subagent_type: "Explore"`, `model: "sonnet"`, all of one round's agents in **one message** so they run concurrently |
| Code search | `git grep -n` / Grep before any Read |
| Reading code | `Read` with `offset`/`limit` (≤80 lines); never dump whole files |
| Edits | `Edit` (the lead only; subagents never edit, commit, or touch git) |

---

## 1. Verification commands

| Name | Command | When |
|---|---|---|
| **fast** | `dart analyze --fatal-infos && dart test test/<module>_test.dart` | after every item |
| **gate** | `make check test` (analyze, format check, full suite) + **smoke** | end of each gate |
| **smoke** | `for b in tk books keybox; do dart run bin/$b.dart --help >/dev/null \|\| echo FAIL $b; done` | gate, and after any `cli` change |
| **native** | `cargo check --manifest-path native/Cargo.toml && make native && dart test test/native_test.dart test/hash_test.dart test/archive_test.dart` | any `native/src/` change |
| **startup A/B** | see §1.1 | any change under `lib/` that adds an import or top-level initializer |

Test names map to modules: `test/<module>_test.dart` for `core async collection cli fs hash http
process tui chrome archive native`; `formats` also runs `test/formats_diff_test.dart`.

### 1.1 Startup A/B (never a standalone number)

Single-run startup drifts ±80 ms on this machine, so a one-off `make bench` proves nothing.
Compare **back-to-back** against the last checkpoint:

```bash
git worktree add -f ../tk-base checkpoint-<prev>        # once per gate
(cd ../tk-base && dart pub get >/dev/null)
for i in 1 2; do
  (cd ../tk-base && dart run tool/bench.dart <modules> -r 8)
  dart run tool/bench.dart <modules> -r 8
done
git worktree remove --force ../tk-base
```

Read the **min-over-bare** column. A module regresses if HEAD's min-over-bare is worse than the
base's in both pairs by more than 10 ms. Quote deltas only, as `base → head`.

Runtime (throughput) changes need their own microbenchmark in the item's commit body
(MB/s or ms/op, base vs head, same run). Under 5 % gain plus more code means **reject**.

### 1.2 Two-strike rollback

1. Item fails **fast** → one corrective attempt (strike 1).
2. Still failing (strike 2) → discard only this item: `git restore --staged --worktree -- .`
   and `git clean -fd -- lib bin tool test native` (both are safe because every earlier item
   is already committed). Record it as `REJECTED (compile|test): <one line>` for the gate
   commit body and move on.
3. Never leave a red tree between items.

### 1.3 Native ABI lockstep

A change to any `extern "C"` signature in `native/src/` bumps **both** `tk_version()` in
`native/src/lib.rs` and `NativeLib._abi` in `lib/src/native/native.dart`. After a bump, every
library in `native/prebuilt/*` reports the old ABI and is refused at load, so rebuild **all**
shipped targets (`make native-all`, or each `make native RUST_TARGET=…` for the dirs present
in `native/prebuilt/`). If a cross toolchain is missing, **do not commit the bump**: reject the
item and say which target could not be built.

---

## 2. Step 0: Baseline

1. `git fetch && git status`: tree clean, `master` == `origin/master`. If not, stop and ask.
2. Run **gate**. Record any failing test names verbatim: these are the *known failures*, and a
   later gate passes if it fails on no other test. A failing analyze or format check means
   stop and fix it first, as its own commit.
3. If `native/prebuilt/<host>/` is missing or older than `native/src/`, run **native**.
4. `git tag -f checkpoint-step0` (local only; tags are never pushed).

---

## 3. Audit item schema

Every subagent prompt includes this schema, the round's scope, and these limits: **at most 10
items, under 150 lines, High/Medium only.** If nothing qualifies, return exactly
`NO_ACTIONABLE_ITEMS`. Each item must cite a real `path:line` that the subagent opened itself.

```markdown
- **[TAG-01] Title** (`lib/src/x/y.dart:12-34`), High | Medium
  - Problem: 1–2 sentences.
  - Fix: a minimal diff, or "delete X; callers use Y".
  - Call-site effect: tokens/lines saved or added at a typical call, or the measured speedup.
  - Blast radius: the files that must change (from `git grep`).
```

Tags: `FEAT BLOAT PERF DOC DISC CONS BUG`.

---

## 4. Round 1: Foundation audits (4 parallel subagents)

| # | Tag | Target | Look for |
|---|---|---|---|
| 1.1 | `FEAT` | facades `lib/*.dart`, `lib/src/{http,formats,chrome,cli}` | capabilities a script really needs that are missing (check first that they don't already exist: XPath, JSONPath, CSS `$`, streaming download, and HTTP verbs all do); verbose signatures; missing Dart 3 modifiers (`final`/`sealed`/`interface`) on public classes |
| 1.2 | `BLOAT` | `lib/src/{core,collection,async,process}`, `lib/src/fs/path.dart`, `bin/` | extensions on `String/List/Map/int` that only one module uses, duplicate helpers, aliases (e.g. a second spelling of one operator), dead code, test-only seams, duplicate `bin/` examples |
| 1.3 | `PERF` | `native/src/*.rs`, `lib/src/native/`, `lib/src/hash/native.dart`, `lib/src/fs/archive.dart`, `lib/src/async/pool.dart`, parsers in `lib/src/formats/` | extra copies across the FFI boundary, `tk_alloc`/`tk_free` pairing on error paths, per-element allocation in hot loops, isolate closures capturing large outer state, missing cleanup on cancel |
| 1.4 | `DOC` | `CONVENTIONS.md`, `GUIDE.md`, `README.md`, `CHANGELOG.md`, public dartdoc | snippets that don't compile against the current API, self-contradicting or obsolete rules, POSIX-only assumptions; `is`/`case` checks on extension types (`Path`, `Row`, `Elements`, `Nodes`), which match any raw `String`/`Map`/`List` after erasure |

## 5. Gate 1: Triage and apply

1. **Triage.** Dedupe across the four reports. For each surviving item, **verify it yourself**
   (open the cited lines; subagents misread code). Drop anything that breaks a `CONVENTIONS.md`
   rule. Rank by the priority rule and cap at **15** accepted items.
2. **Batch A: deletions** (`BLOAT`, doc deletions). One item per commit, `refactor: …`.
3. **Batch B: refactors and perf** (`PERF`). Run **native** and §1.3 if Rust changes, and
   **startup A/B** if imports change. Commit as `perf: …` with the measurement in the body.
4. **Batch C: additions** (`FEAT`, `DOC` fixes). Each new API gets tests for the cases that
   apply: happy path; edge (empty, boundary, unicode); failure (the exception or `Left` it
   documents); cancellation, *if it is async*: it stops under `Cancel.scope`; differential,
   *if it replaces an engine*: same output as the reference (see `formats_diff_test.dart`).
   Commit as `feat: …`.
5. **Docs move with code.** Every commit that changes public API also updates `README.md`,
   `GUIDE.md`, `CHANGELOG.md` (Unreleased, one table row or bullet) and, for a new rule,
   `CONVENTIONS.md`.
6. **Close.** Run **gate** and the **startup A/B** over every module touched. Write `git commit --allow-empty -m "chore(gate-1): audit record"` whose body lists accepted / rejected items with
   reasons. Push, then `git tag -f checkpoint-gate1`.

## 6. Round 2: Design consistency (2 parallel subagents)

The subagents audit **HEAD after Gate 1**, not the original code.

| # | Tag | Look for |
|---|---|---|
| 2.1 | `DISC` | workflows reachable only by knowing a top-level function exists; an entry point that is missing from its facade (`Http`, `Path`, `Shell`, `Hash`, `Console`, …) **when adding it doesn't lengthen the common call**. Short globals such as `run(...)` stay. |
| 2.2 | `CONS` | naming drift between sibling APIs (e.g. `ConsoleTheme`/`TuiTheme` field names, HTTP verb vs `Client` method names), parameter order of related functions, `null` vs throw vs `Either` for the same kind of failure, `_ =>` wildcards over sealed types |

## 7. Gate 2: Harmonize

Same procedure as Gate 1, steps 1, 5 and 6 (one item per commit, `refactor: …`), with these
additions:

- A rename `git grep`s the old name across the whole repo, including `*.md` and dartdoc, and must
  finish with zero hits outside `CHANGELOG.md`.
- Run **smoke** after every `cli` or `tui` item.
- Close with `chore(gate-2): audit record`, push, `git tag -f checkpoint-gate2`.

## 8. Round 3: Hardening (lead does it, no subagents)

| Task | Done when |
|---|---|
| 3.1 Cancellation & errors | a test shows that cancelling the scope during each async API in `async`, `http`, `process` and `chrome` leaves no timer, isolate, process or socket open, and that worker isolate errors rethrow with the original stack trace |
| 3.2 Platform parity | **POSIX** (runnable here): pipefail exit code, signal forwarding, CRLF input in parsers. **Windows** (not runnable on this macOS host): use unit tests on the *built* command line and path logic, e.g. `cmd /d /c` for built-ins, refusal of unsafe `cmd` args, `\` separators, and atomic-replace retry when a file is locked. Label anything not executable here as `unverified-on-windows` in the commit body. |
| 3.3 Final | **gate** passes except *known failures*, `git status` is clean, and `master` is pushed |

Commit each fix as `fix: …`. End the session with a short summary in chat: the items applied
per gate, the items rejected and why, the A/B deltas, and anything left unverified.
