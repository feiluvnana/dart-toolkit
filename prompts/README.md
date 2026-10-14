# prompts

One prompt per kind of improvement. Paste a file into a fresh agent session at the repo root.
Each one is self-contained and covers its whole field; run them one at a time, since several of them edit lib/.

| File | Use it to |
|---|---|
| FEATURE.md | find missing features, redundant ones, and modules to add, merge or remove |
| BUGPERF.md | hunt bugs, leaks, hangs and slow paths, and fix them with tests |
| ERGONOMIC.md | make call sites shorter, clearer and easier to discover |
| ARCHITECTURE.md | review module boundaries, dependencies, layering and the shared model |
| PLATFORM.md | check Windows, macOS and Linux behaviour and terminal differences |
| SECURITY.md | review injection, path traversal, TLS, untrusted input and secrets |
| TESTS.md | find coverage gaps and flaky or slow tests, and add regression tests |
| DOCS.md | bring VISION.md, doc comments and examples in line with the code |
| DOGFOOD.md | build real scripts on the library and record every friction point |
| RELEASE.md | check pub.dev readiness: pubspec, score, changelog, versioning |
| NOBRAIN.md | run all of the above, in order, as one autonomous pipeline with gates |

Every prompt starts with the same base rules (Context), so they agree with each other.
