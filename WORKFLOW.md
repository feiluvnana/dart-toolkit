# Multi-Agent Audit & Modernization Workflow

This document defines the structured, three-round auditing and refinement workflow for the codebase. Orchestrating agents must execute this pipeline sequentially, spawning dedicated subagents for each audit domain, persisting findings into structured Markdown reports, and gating progression between rounds.

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

---

## Workflow Architecture Overview

```mermaid
flowchart TD
    subgraph Round 1: Foundation & Defect Audits
        A1["Subagent 1.1: Features & Ergonomics\n(AUDIT_FEATURES.md)"]
        A2["Subagent 1.2: Bloat & Simplification\n(AUDIT_BLOAT.md)"]
        A3["Subagent 1.3: Performance & FFI\n(AUDIT_PERFORMANCE.md)"]
        A4["Subagent 1.4: Conventions & Docs Defects\n(AUDIT_CONVENTIONS.md)"]
    end

    G1{"Gate 1: Triage, Clean Cut & Implement Round 1"}

    subgraph Round 2: Design & Consistency
        B1["Subagent 2.1: Brevity & Discoverability\n(AUDIT_DISCOVERABILITY.md)"]
        B2["Subagent 2.2: Architectural Consistency\n(AUDIT_CONSISTENCY.md)"]
    end

    G2{"Gate 2: Triage & Harmonize Round 2"}

    subgraph Round 3: Bug Fixing & Hardening
        C1["Cross-Platform Verification & Edge Cases\n(Windows vs. POSIX, Race Conditions)"]
        C2["Verification Suite: dart analyze & full test run"]
        C3["Git Commit & Push"]
    end

    A1 --> G1
    A2 --> G1
    A3 --> G1
    A4 --> G1
    G1 --> B1
    G1 --> B2
    B1 --> G2
    B2 --> G2
    G2 --> C1
    C1 --> C2
    C2 --> C3
```

---

## Standardized Audit Item Schema

All subagents **must** format every finding in their respective `AUDIT_*.md` files using this exact structure to facilitate systematic review:

```markdown
### [TAG-01] Short Descriptive Title
- **Location**: `lib/src/path/to/file.dart#L12-L34` or `native/src/...` or `CONVENTIONS.md#L...`
- **Severity**: High | Medium | Low
- **Problem**: Concise description of the defect, friction, bloat, or inefficiency.
- **Proposed Solution**: Exact code diff, replacement signature, or revised convention.
- **Rationale & Impact**: Concrete benefit (e.g. autocompletion clarity, memory reduction, cross-platform safety).
```

---

## Round 1: Foundation Audits (Parallel Subagents)

The lead agent spawns four independent subagents concurrently. Each subagent reads the relevant parts of the codebase, native Rust code, documentation, and conventions, writing its findings to its designated output file.

### Subagent 1.1: Missing Features & API Ergonomics
- **Role**: `Feature & Ergonomics Auditor`
- **Output Target**: `AUDIT_FEATURES.md`
- **Scope**:
  - Identify missing capabilities compared to modern toolkits (e.g. streaming transformations, HTTP verb coverage, compression formats, XPath/DOM queries).
  - Identify clunky, verbose, or high-friction API signatures (redundant parameter requirements, lack of factory constructors, awkward type conversions).
  - Propose clean, expressive method signatures and realistic usage examples.

### Subagent 1.2: Bloat & Code Simplification
- **Role**: `Bloat & Simplification Auditor`
- **Output Target**: `AUDIT_BLOAT.md`
- **Scope**:
  - Identify loose extensions on primitive SDK types (`String`, `List`, `Map`, `int`) that pollute global autocompletion without strong justification.
  - Identify redundant methods, unnecessary overloads, duplicate helper classes, and dead code paths.
  - Recommend exact items to prune completely under the **Clean-Cut Policy**.

### Subagent 1.3: Performance & Native FFI Optimization
- **Role**: `Performance & FFI Auditor`
- **Output Target**: `AUDIT_PERFORMANCE.md`
- **Scope**:
  - Identify hot-path bottlenecks, unnecessary intermediate memory allocations, and redundant buffer copies.
  - Review the native Rust layer (`native/src/*.rs`, `Cargo.toml`) and the Dart FFI boundary (`NativeBridge`, pointer allocations, worker isolate boundaries).
  - Evaluate I/O performance: file stream chunking, socket buffering, and process pipeline backpressure.
  - Propose algorithmic and memory optimizations with quantified impact.

### Subagent 1.4: Conventions & Documentation Defects
- **Role**: `Conventions & Specs Auditor`
- **Output Target**: `AUDIT_CONVENTIONS.md`
- **Scope**:
  - Audit `CONVENTIONS.md`, `GUIDE.md`, `README.md`, and top-level library docstrings for internal defects, obsolete advice, and self-contradictory rules.
  - Scrutinize whether any written conventions are themselves defective, dogmatic, or counter-productive (e.g. banning necessary abstractions, enforcing brittle patterns, or assuming POSIX-only environments).
  - Identify gaps where conventions are silent or ambiguous, causing divergent implementations across modules.
  - Validate that documented code snippets match actual current runtime signatures and behavior.

---

## Gate 1: Implementation & Clean-Cut Consolidation

Before proceeding to Round 2:
1. The lead agent reviews `AUDIT_FEATURES.md`, `AUDIT_BLOAT.md`, `AUDIT_PERFORMANCE.md`, and `AUDIT_CONVENTIONS.md`.
2. Apply the **Gate 1 Triage Priority Rule**: resolve conflicts favoring bloat removal and clean ergonomics over speculative additions.
3. Apply the **Clean-Cut Policy**: remove dead/bloated code immediately without `@Deprecated` shims. Refactor call sites across `lib/`, `bin/`, `tool/`, and `test/`.
4. Update `CONVENTIONS.md`, `GUIDE.md`, and docstrings to correct any defects found in Subagent 1.4.
5. Validate compilation and tests (`dart analyze`, `dart test`).
6. Remove intermediate Round 1 audit files once all accepted changes are committed.

---

## Round 2: API Refinement & Consistency (Parallel Subagents)

Once the core foundation, bloat, performance, and conventions have been resolved in Round 1, the lead agent spawns two focused subagents to polish the public API.

### Subagent 2.1: API Brevity & Discoverability
- **Role**: `Discoverability Auditor`
- **Output Target**: `AUDIT_DISCOVERABILITY.md`
- **Scope**:
  - Evaluate how easy it is for an engineer starting from an empty file to discover functionality via autocomplete facades (e.g. `Http.*`, `Doc.*`, `Shell.*`, `Hash.*`, `Path.*`).
  - Balance brevity with discoverability: ensure concise syntax without polluting primitive types.
  - Identify hidden or hard-to-find features that lack discoverable entry points.

### Subagent 2.2: Architecture & Convention Consistency
- **Role**: `Consistency Auditor`
- **Output Target**: `AUDIT_CONSISTENCY.md`
- **Scope**:
  - Audit naming conventions across all modules (e.g. `ConsoleTheme` vs. `TuiTheme`, verb names in HTTP vs. Client).
  - Verify parameter ordering conventions across related functions.
  - Audit return type semantics (nullable vs non-nullable exceptions, `Either` vs thrown errors).
  - Ensure uniform adherence to the updated repository conventions in `CONVENTIONS.md`.

---

## Gate 2: Implementation & Harmonization

Before proceeding to Round 3:
1. The lead agent reviews `AUDIT_DISCOVERABILITY.md` and `AUDIT_CONSISTENCY.md`.
2. Apply API renames, facade additions, and consistency alignments (clean cuts only, no deprecated shims).
3. Update tests and documentation to reflect harmonized conventions.
4. Verify with `dart analyze` and relevant test suites.
5. Clean up Round 2 audit files.

---

## Round 3: Bug Fixing & Hardening

Round 3 focuses on correctness, reliability, and edge-case testing:
1. **Edge Case Resolution**:
   - Address silent failures, unhandled stream cancellations, and race conditions.
   - Audit cross-platform compatibility:
     - Windows cmd/PowerShell built-ins, batch files, quoting rules, and AutoRun registry immunity (`/d /c`).
     - POSIX shell execution parity.
     - Windows path separators (`\` vs `/`), file locking semantics, and CRLF line endings.
   - Verify atomic I/O guarantees (temporary-write-and-rename replacement).
2. **Verification Suite**:
   - Run `dart analyze` to ensure 0 errors and 0 warnings.
   - Run `dart test` across all unit, integration, and platform tests.
3. **Completion**:
   - Delete any temporary scratch scripts or transient audit files.
   - Commit and push all verified changes with concise, informative commit messages.
