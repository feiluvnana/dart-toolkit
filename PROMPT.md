# PROMPT.md — generate `COMPARE.md` for this repo

Act as a **Senior Software Architect and Library Maintainer**. Analyze the
library codebase and generate a comprehensive `COMPARE.md` documenting the
transition from the current syntax/API to a proposed new syntax/API that is
better (compare the current version with your proposed new API, wherever you
have anything better).

## Required structure for `COMPARE.md`

1. **`# Library Syntax & Architecture Migration Guide`**
   - Brief high-level summary of the architectural shift (e.g. DX
     improvements, type safety, memory/performance enhancements).
   - **Folder architecture**: how the code is laid out (public facades,
     private internals, examples, tests, tooling) and what the proposal
     changes about it.
   - **Dependency choices**: per capability, whether it comes from the SDK, a
     third-party package, or in-house code — and why.

2. **`## Module: [Module Name / Component]`** (every module, in repo order)
   - **Old Syntax / API:** code snippet illustrating the current approach.
   - **New Proposed Syntax / API:** code snippet illustrating the updated,
     cleaner approach.
   - **Why This Change Was Made:** design rationale (e.g. reducing
     boilerplate, clearer separation of concerns, better ergonomic DX).
   - **Bugs & Performance Bottlenecks Addressed:** specific flaws in the old
     syntax/implementation (e.g. race conditions, unnecessary allocations,
     memory leaks, confusing edge cases, sync/async blocking issues) and how
     the new design solves them. Highlight open trade-offs or alternatives
     considered.

## Instructions for analysis

- Examine the codebase first: entry points, the import/export graph, the
  public surface of each module, error handling, resource lifetimes, and the
  real example scripts.
- Side-by-side or sequential examples must be syntactically accurate and
  idiomatic, in the codebase's own style; proposals are additive by default.
- Be explicit about performance implications (e.g. `O(n)` vs `O(1)`, reduced
  GC pressure, asynchronous overhead).
