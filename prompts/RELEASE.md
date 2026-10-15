# Release readiness

Get the package ready for pub.dev.

Check:
- **pubspec:** name, description (60–180 chars), homepage/repository, topics, SDK constraint, and that dependency versions are the tightest that work. Does `dart pub publish --dry-run` pass with no warnings?
- **Score:** run `pana` and fix every point lost (docs, platforms, analysis, dependency health, examples).
- **Platforms:** declare the platforms honestly (no web if dart:io is used).
- **API surface:** `dart pub global run dart_apitool` (or a manual export list) to see what is public. Remove accidental exports.
- **Versioning:** propose a version from the change since the last tag, then write CHANGELOG.md and the README install line.
- **Size:** keep the package archive small: .pubignore for tool/, projects/ and test fixtures if needed.
- **License and headers:** confirm both.

Do not publish or push; stop after the dry run passes and report the remaining manual steps (tag, release notes, verified publisher).

## Context (same in every prompt)
- dart_toolkit, branch master: a Dart scripting toolkit. docs/VISION.md is the intended API; lib/*.dart is the public surface (lib/src is private).
- README.md has the tour; projects/rawfree.dart is a real Tui app built on the library; docs/PLAN.md holds Windows and Linux handoffs.
- Priorities: speed (runtime, then startup) > call-site brevity = discoverability > the rest.
- Every module works alone and composes: `Reader | Pipe > Writer`, Future mirrors (no inner `await`), actions return the receiver, readings are methods, named params over chains.
- Names: short, one word when it reads one way, the same word for the same idea in every module (see docs/VISION.md §1).
- Pure Dart plus pub packages; no native code, no codegen, no sync twins. No backward compatibility: rename, merge or delete freely.
- Tui is alternate-screen only and has no colour by default (`accent:` opts in); scrollback output belongs to Console.
- Every bug fix gets a regression test. Before each commit: `dart analyze lib test projects tool` is clean and the full `dart test` passes.
- One commit per finding, message `<area>: <imperative summary>`, no trailers, never push. Do not commit prompt output files unless asked.
- Never signal pid -1 or 0, or any process you did not spawn.
- Measure speed claims with back-to-back A/B runs; this machine drifts ±80 ms.
