# Multi-Agent Audit & Modernization Workflow

This document defines the hardened, three-round auditing and refinement workflow for the codebase. Orchestrating agents must execute this pipeline sequentially, spawning dedicated subagents for each audit domain, persisting findings into structured Markdown reports, and gating progression between rounds.

---

## Core Operating Principles

1. **Clean-Cut Policy (Zero Deprecations)**:
   - This is a personal project. **Never** use `@Deprecated` annotations, backward-compatibility wrapper shims, or legacy aliases.
   - When an API or extension is removed or renamed, make a clean cut: delete or rename it immediately, and update all call sites, examples, and tests across `lib/`, `bin/`, `tool/`, and `test/`.
2. **Gate 1 Triage Priority**:
   - When recommendations from different audit streams conflict, apply strict prioritization:
     $$\text{Bloat Pruning} > \text{API Ergonomics} > \text{Performance} > \text{Speculative Features}$$
   - Only accept new features if they fill genuine standard capabilities (e.g. streaming, missing HTTP verbs, DOM selectors), never speculative "nice-to-haves".
3. **Full Stack & Cross-Platform Scope**:
   - Audits cover the entire repository: Dart libraries (`lib/`), CLI tools (`bin/`), test suites (`test/`), internal tooling (`tool/`), specifications (`CONVENTIONS.md`, `GUIDE.md`), and native Rust FFI code (`native/src/*.rs`, `Cargo.toml`).
   - Cross-platform parity (Windows cmd/PowerShell vs. POSIX bash, path separators, file locking, and line endings) is a primary requirement.
4. **Decoupled Benchmark Guardrails**:
   - `tool/bench.dart` measures **module startup and import compilation latency**, not runtime throughput. Startup time must not regress by >10 ms for any module.
   - Runtime performance refactors (FFI, hashing, compression, I/O) must be verified via dedicated microbenchmarks or throughput tests (MB/s, memory allocations). If throughput gains are negligible (<5%) but complexity increases, reject the change.
5. **Model Tiering & Quorum for Efficiency**:
   - Auditing and scanning subagents run on fast, wide-context models (`Model: 'flash'`).
   - Orchestration, triage, and complex code refactoring at Gates 1, 2, and 3 run on `inherit` (or `pro`).
   - **Fail-Open Quorum**: If 3 of 4 subagents complete in Round 1 (or 1 of 2 in Round 2) within a 5-minute timeout, the gate proceeds immediately. The missing domain is logged and deferred.
6. **Two-Strike Rollback Protocol**:
   - Every audit item is applied as an isolated edit. Run `dart analyze --fatal-infos`.
   - If compilation fails, allow **one** corrective fix (Strike 1).
   - If compilation still fails (Strike 2), **immediately rollback with `git reset --hard HEAD`**, mark the item `[REJECTED - COMPILATION FAILURE]`, and move to the next item. Never leave the working tree in a broken state.
7. **Audit Provenance (Archive, Don't Delete)**:
   - Instead of deleting audit reports, move them to `.audits/round1/` and `.audits/round2/`. This preserves the decision log, rejected items, and rationale for future reference.

---

## Workflow Architecture Overview

```mermaid
flowchart TD
    S0["Step 0: Baseline Health Check\n(analyze, format, test, CLI smoke, git tag)"] --> R1

    subgraph R1["Round 1: Foundation Audits (Parallel 'flash' Subagents, Max 10 items each)"]
        A1["Subagent 1.1: Features & Ergonomics\n(AUDIT_FEATURES.md)\nFocus: Public facades & missing capabilities"]
        A2["Subagent 1.2: Bloat & Simplification\n(AUDIT_BLOAT.md)\nFocus: SDK extensions & dead code"]
        A3["Subagent 1.3: Performance & FFI\n(AUDIT_PERFORMANCE.md)\nFocus: Rust native, I/O & memory"]
        A4["Subagent 1.4: Conventions & Docs Defects\n(AUDIT_CONVENTIONS.md)\nFocus: Specs, docstrings & guides"]
    end

    R1 --> G1{"Gate 1: Triage & Phased Clean Cuts\n1. Deduplicate & Triage\n2. Batch A: Pure Deletions\n3. Batch B: Internal Refactors & Rust FFI Rebuild\n4. Batch C: Essential Additions (5-Point Test Gate)\n5. Checkpoint Tag: checkpoint-gate1"}

    subgraph R2["Round 2: Design & Consistency (Parallel 'flash' Subagents)"]
        B1["Subagent 2.1: Brevity & Discoverability\n(AUDIT_DISCOVERABILITY.md)\nFocus: Autocomplete facades & syntax"]
        B2["Subagent 2.2: Architectural Consistency\n(AUDIT_CONSISTENCY.md)\nFocus: Naming, params & return types"]
    end

    G1 --> R2
    R2 --> G2{"Gate 2: API Harmonization & Living CLI Guard\n1. Apply clean renames & alignments\n2. Sync GUIDE.md, README.md, docstrings\n3. Smoke-test bin/ CLI executables\n4. Checkpoint Tag: checkpoint-gate2"}

    subgraph R3["Round 3: Bug Fixing & Hardening"]
        C1["Task 3.1: Stream Cancellation & Error Rethrows"]
        C2["Task 3.2: Host Platform Parity (Windows cmd/PowerShell vs. POSIX)"]
        C3["Task 3.3: Final Full Verification Suite (analyze, format, test, CLI smoke)"]
        C4["Completion: Git Commit & Summary Report"]
    end

    G2 --> R3
    C1 --> C2 --> C3 --> C4
```

---

## Step 0: Baseline Health Check

Before spawning subagents:
1. **Compilation & Formatting Check**:
   ```bash
   dart analyze --fatal-infos
   dart format --output=none --set-exit-if-changed lib bin test tool
   ```
2. **Baseline Test Suite**:
   ```bash
   dart test
   ```
   *(If flaky timing assertions occur due to environmental load, record failures so regressions are machine-differentiable).*
3. **Native Rust Binary Verification**:
   - If `native/src/` has been modified or `native/prebuilt/` is missing:
     ```bash
     cargo check --manifest-path native/Cargo.toml
     dart run tool/build_native.dart
     ```
4. **Living CLI Smoke Test**:
   ```bash
   dart run bin/tk.dart --help
   dart run bin/books.dart --help
   dart run bin/keybox.dart --help
   ```
5. **Git Checkpoint Tag**:
   ```bash
   git tag -f checkpoint-step0
   ```

---

## Standardized Audit Item Schema

All subagents **must** adhere to this strict schema.
- **Hard Limit**: Maximum **10 highest-impact items** per subagent.
- **Budget**: Total output **under 300 lines** per file. No full-file code dumps.
- **Constraint**: `CONVENTIONS.md` §1 strictly applies ("A conversion is the way in. Nothing else goes on String, Iterable or Map"). Do NOT propose loose extensions on primitive types.

```markdown
### [TAG-01] Short Descriptive Title
- **Location**: `lib/src/path/to/file.dart#L12-L34` (or `native/src/...`, `CONVENTIONS.md#L...`)
- **Severity**: High | Medium | Low
- **Problem**: Concise description of the defect, friction, bloat, or inefficiency.
- **Proposed Solution**: Exact code diff, replacement signature, or revised convention.
- **Rationale & Impact**: Concrete benefit (e.g. autocompletion clarity, memory reduction, cross-platform safety).
```

---

## Round 1: Foundation Audits (Parallel Subagents)

The lead agent spawns four independent subagents concurrently (`Model: 'flash'`). Subagents are read-only and must never mutate code or git state.

### Subagent 1.1: Missing Features & API Ergonomics
- **Role**: `Feature & Ergonomics Auditor`
- **Output Target**: `AUDIT_FEATURES.md`
- **Target Matrix**:
  - Public facades: `lib/*.dart`
  - High-level domains: `lib/src/http/`, `lib/src/formats/`, `lib/src/chrome/`, `lib/src/cli/`
- **Scope**:
  - Missing capabilities compared to modern toolkits (e.g. streaming request bodies, HTTP verb symmetry, compression formats, XPath/DOM queries).
  - Clunky or verbose API signatures (redundant parameter requirements, lack of factory constructors, awkward type conversions).
  - Enforce Dart 3 class modifiers (`abstract interface class`, `final class`, `sealed class`) on public APIs.

### Subagent 1.2: Bloat & Code Simplification
- **Role**: `Bloat & Simplification Auditor`
- **Output Target**: `AUDIT_BLOAT.md`
- **Target Matrix**:
  - Core type extensions: `lib/src/core/`, `lib/src/fs/path.dart`
  - Internal abstractions: `lib/src/async/`, `lib/src/collection/`, `lib/src/process/`
- **Scope**:
  - Loose extensions on primitive SDK types (`String`, `List`, `Map`, `int`) that pollute global autocompletion.
  - Redundant methods, unnecessary overloads, duplicate helper classes, and dead code paths.
  - Recommend exact items to prune completely under the **Clean-Cut Policy**.

### Subagent 1.3: Performance & Native FFI Optimization
- **Role**: `Performance & FFI Auditor`
- **Output Target**: `AUDIT_PERFORMANCE.md`
- **Target Matrix**:
  - Native Rust code: `native/src/*.rs`, `native/Cargo.toml`
  - FFI boundaries & workers: `lib/src/hash/native.dart`, `lib/src/fs/archive.dart`, `lib/src/async/pool.dart`
  - Hot loops & I/O pipelines: `lib/src/fs/`, `lib/src/process/`
- **Scope**:
  - Hot-path bottlenecks, unnecessary intermediate memory allocations, and redundant buffer copies.
  - Rust FFI boundary: pointer allocation safety (`NativeBridge.alloc`), copying overhead, and isolate boundary costs.
  - Record churn in high-throughput hot paths (parsers, streaming loops).
  - Isolate pool safety: ensure worker closures do not capture outer scope, and ensure deterministic cleanup on cancellation.

### Subagent 1.4: Conventions & Documentation Defects
- **Role**: `Conventions & Specs Auditor`
- **Output Target**: `AUDIT_CONVENTIONS.md`
- **Target Matrix**:
  - Guidelines & documentation: `CONVENTIONS.md`, `GUIDE.md`, `README.md`
  - Public docstrings: library-level and class-level doc comments across all `lib/*.dart` and `lib/src/`
- **Scope**:
  - Internal defects, obsolete advice, and self-contradictory rules in specifications.
  - Dogmatic or counter-productive conventions (e.g. banning necessary abstractions, enforcing brittle patterns, or assuming POSIX-only environments).
  - Extension type erasure traps: audit all `extension type` usages (e.g. `Path`) and forbid dangerous `is Path` or `case Path` type checks where runtime erasure causes false matches against raw `String`.
  - Validate that documented code snippets match actual current runtime signatures and behavior.

---

## Gate 1: Implementation & Phased Clean Cuts

Before proceeding to Round 2, the lead agent executes a phased consolidation with micro-commits and the **Two-Strike Rollback Protocol**:

1. **Deduplication & Triage**:
   - Merge overlapping findings across the four `AUDIT_*.md` files. Discard any item violating `CONVENTIONS.md` §1.
   - Apply the **Gate 1 Triage Priority Rule**: Bloat Pruning > Ergonomics > Performance > Speculative Features.
   - Cap accepted items at **maximum 15 total changes** to avoid compiler cascades.
2. **Batch A (Pure Deletions & Clean Cuts)**:
   - Delete dead code, duplicate helpers, and polluting extensions immediately without `@Deprecated` shims.
   - Update call sites across `lib/`, `bin/`, `tool/`, and `test/` per item.
   - Commit each change: `refactor(batch-a): [BLOAT-XX] prune ...`.
   - Verify with `dart analyze --fatal-infos` and `dart test`.
3. **Batch B (Internal Refactors & FFI Optimizations)**:
   - Apply accepted performance improvements and FFI memory optimizations.
   - **Native Rust Rebuild**: If `native/src/` is touched:
     ```bash
     cargo check --manifest-path native/Cargo.toml
     dart run tool/build_native.dart
     dart test test/native_test.dart test/hash_test.dart test/archive_test.dart
     ```
   - **ABI Lockstep Rule**: Any change to exported C functions must increment `tk_version()` in `native/src/lib.rs` AND `NativeLib._abi` in `lib/src/native/native.dart`.
   - Check startup impact with `dart run tool/bench.dart`.
   - Commit: `perf(batch-b): [PERF-XX] optimize ...`.
4. **Batch C (Essential Feature Additions & 5-Point Test Gate)**:
   - Implement accepted high-value ergonomic additions.
   - Update `CONVENTIONS.md` to fix any spec defects.
   - **5-Point Test Gate**: Every new API must have tests covering:
     1. *Happy path*: Canonical usage.
     2. *Edge cases*: Empty inputs, boundary lengths, unicode.
     3. *Failure semantics*: Expected exceptions or `Either.Left` outcomes.
     4. *Cancellation*: Immediate halting under `Cancel.scope`.
     5. *Differential*: Replaced engines match ground-truth packages.
   - Commit: `feat(batch-c): [FEAT-XX] add ...`.
5. **Checkpoint & Archive**:
   - Move `AUDIT_*.md` files into `.audits/round1/`.
   - Tag checkpoint: `git tag -f checkpoint-gate1`.

---

## Round 2: API Refinement & Consistency (Parallel Subagents)

Once the core foundation, bloat, performance, and conventions have been resolved in Round 1, the lead agent spawns two focused subagents (`Model: 'flash'`, Max 10 items each).

### Subagent 2.1: API Brevity & Discoverability
- **Role**: `Discoverability Auditor`
- **Output Target**: `AUDIT_DISCOVERABILITY.md`
- **Scope**:
  - Autocomplete discoverability: Ensure central facades (`Http.*`, `Doc.*`, `Shell.*`, `Hash.*`, `Path.*`) expose all key workflows without relying on global function imports.
  - Balance brevity with discoverability: clean method names without polluting primitive types.
  - Identify hidden or hard-to-find features that lack discoverable entry points.

### Subagent 2.2: Architecture & Convention Consistency
- **Role**: `Consistency Auditor`
- **Output Target**: `AUDIT_CONSISTENCY.md`
- **Scope**:
  - Uniform naming conventions across all modules (e.g. `ConsoleTheme` vs. `TuiTheme`, verb names in HTTP vs. Client).
  - Consistent parameter ordering conventions across related functions.
  - Return type semantics: nullable vs non-nullable exceptions, `Either` vs thrown errors.
  - Pattern matching exhaustiveness: eliminate wildcard escapes (`_ =>`) on sealed domain states.

---

## Gate 2: Implementation & Living CLI Guard

Before proceeding to Round 3:
1. The lead agent reviews `AUDIT_DISCOVERABILITY.md` and `AUDIT_CONSISTENCY.md`.
2. Apply API renames, facade additions, and consistency alignments (clean cuts only, no deprecated shims). Apply the Two-Strike Rollback Protocol.
3. Commit changes micro-batched: `refactor(gate-2): [CONS-XX] align ...`.
4. **Living CLI & Tooling Smoke Test**:
   ```bash
   dart run bin/tk.dart --help
   dart run bin/books.dart --help
   dart run bin/keybox.dart --help
   ```
5. **Documentation Drift Guard**:
   - Update all code examples in `GUIDE.md`, `README.md`, and docstrings to reflect new names and signatures.
   - Run `dart format --output=none --set-exit-if-changed lib bin test tool`.
6. **Checkpoint & Archive**:
   - Move Round 2 audit files into `.audits/round2/`.
   - Tag checkpoint: `git tag -f checkpoint-gate2`.

---

## Round 3: Bug Fixing & Hardening

Round 3 focuses on correctness, reliability, and edge-case testing partitioned into discrete tasks:

### Task 3.1: Stream Cancellation & Error Handling
- Verify unhandled stream cancellations and isolate deadlocks under `Cancel.scope`.
- Verify that errors in worker isolates rethrow with original stack traces and clean up resources.

### Task 3.2: Host Platform Parity
- **Windows Parity**:
  - Verify that `cmd.exe` built-ins run with `/d /c` to prevent AutoRun registry script failure.
  - Verify argument quoting rules and path separator handling (`\` vs `/`).
  - Verify file-locking resilience during atomic replace operations.
- **POSIX Parity**:
  - Verify pipefail semantics and signal forwarding.

### Task 3.3: Final Full Verification Suite
Run the complete, machine-verifiable verification suite:
```bash
# 1. Code formatting
dart format --output=none --set-exit-if-changed lib bin test tool

# 2. Strict analysis
dart analyze --fatal-infos

# 3. Full test suite
dart test

# 4. CLI living integration tests
dart run bin/tk.dart --help
dart run bin/books.dart --help
dart run bin/keybox.dart --help
```

### Task 3.4: Completion & Commit
- Ensure working tree is clean.
- Commit all hardened bug fixes with descriptive messages.
- Leave git branch verified and ready for review or push.
