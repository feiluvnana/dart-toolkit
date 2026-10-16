---
name: dart-lib-release
description: Check dart_toolkit's pub.dev readiness — pubspec, pana score, platforms, public API surface, version proposal, CHANGELOG, package size, license — and stop after a clean `dart pub publish --dry-run`. Use when preparing a release or asked whether the package is ready to publish.
---

# dart-lib-release

Read [../dart-lib-audit/references/rules.md](../dart-lib-audit/references/rules.md) first. **Never publish, tag or push.** The user picks the version.

## Check

- **pubspec:** name, description (60–180 chars), homepage/repository, topics, SDK constraint; dependency constraints are the tightest that work (`dart pub downgrade` then the gate, then `dart pub upgrade`).
- **Dry run:** `dart pub publish --dry-run` passes with no warnings. A dirty-tree warning caused by another session's work is reported, not "fixed" by committing their files.
- **Score:** `dart pub global run pana --no-warning .` (activate it if missing); fix every point lost that is the library's to fix (docs, platforms, analysis, formatting, dependency health). No `example/` is the user's choice: report it, do not add one.
- **Platforms:** declared honestly (dart:io ⇒ no web).
- **API surface:** list what each lib/*.dart exports (`dart pub global run dart_apitool` or a manual export list); accidental exports become removal findings.
- **Versioning:** compare against the last tag (`git describe --tags --abbrev=0`) and pub.dev; propose a version from the changes (breaking ⇒ minor bump below 1.0) and let the user pick. Then CHANGELOG.md gets the section and README.md the install line.
- **Size:** keep the archive small; .pubignore keeps test/, tool/, projects/, docs/ and .claude/ out.
- **License and headers:** LICENSE present and matching pubspec; no stray headers.
- **Docs:** `dart doc` has zero warnings; the README tour compiles.

Fixes are one commit each (`release: …`), gated by `dart analyze lib test projects tool` and the full `dart test`.

## Report (chat)

pana before/after, dry-run result and archive size, proposed version with reasons, and the manual steps left for the user (commit or drop other work, set the version, tag, `dart pub publish`, verified publisher).
