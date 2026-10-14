# PROMPT.md — generate `PROPOSAL.md` for this repo

Act as a **Senior Software Architect and Library Maintainer**. Analyze the
library codebase and generate a comprehensive `PROPOSAL.md`: take the good
ideas of the current API and make them better — propose a new syntax/API
wherever you have anything better. Backward compatibility is not a concern:
replacing with good syntax is always OK, even if it breaks existing call sites.

## Required structure for `PROPOSAL.md`

1. **`# Library Syntax & Architecture Proposal Guide`**
   - Brief high-level summary of the proposed shift (e.g. DX improvements,
     type safety, memory/performance enhancements) and which strengths of
     the current API are kept as-is.
   - **Folder architecture**: how the code is laid out (public facades,
     private internals, examples, tests, tooling) and what the proposal
     changes about it.
   - **Dependency choices**: per capability, whether it comes from the SDK, a
     third-party package, or in-house code — and why.

2. **`## Module: [Module Name / Component]`** (every module, in repo order)
   - **Current Syntax / API:** code snippet illustrating the current approach
     and the good idea in it worth keeping.
   - **Proposed Syntax / API:** code snippet illustrating the improved
     approach, building on that good idea.
   - **Why This Change Was Made:** design rationale (e.g. reducing
     boilerplate, clearer separation of concerns, better ergonomic DX).
   - **Bugs & Performance Bottlenecks Addressed:** specific flaws in the
     current syntax/implementation (e.g. race conditions, unnecessary
     allocations, memory leaks, confusing edge cases, sync/async blocking
     issues) and how the new design solves them. Highlight open trade-offs
     or alternatives considered.

## Instructions for analysis

- Examine the codebase first: entry points, the import/export graph, the
  public surface of each module, error handling, resource lifetimes, and the
  real example scripts.
- Fix ambiguous names: a name says what the call does (`waitFor`, not `wait`), with no
  abbreviations. Brevity comes from fewer calls and parameters, never from shorter names.
- Prefer the best syntax over compatibility: keep the good ideas of the
  current API, but replace freely wherever the new design is cleaner — no
  need to keep old call sites compiling, no forwarders, no deprecation path.
- Side-by-side or sequential examples must be syntactically accurate and
  idiomatic.
- Be explicit about performance implications (e.g. `O(n)` vs `O(1)`, reduced
  GC pressure, asynchronous overhead).
