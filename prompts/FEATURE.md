# Feature review

Decide what the library should DO. Code quality, bugs and naming are out of scope here.

Judge against real scripting work (scraping, downloading, file and archive chores, CLI tools, terminal UIs, automation) and against what people use elsewhere: Python (httpx, selectolax/bs4, rich, typer, pathlib, shutil), Node (zx, execa, got, cheerio, puppeteer, ink), and Go/Rust CLI staples.

Report, each item with evidence (a call site in projects/ or the README tour, or a 5–15 line "today vs proposed" snippet you actually ran):
1. **Missing:** tasks a script often needs that take more than 5 lines today, or cannot be done at all. Rank them by how often a real script hits them.
2. **Redundant:** members, params or modules that duplicate another way, that no example, project or doc uses, or that a plain-Dart one-liner already covers. Say what replaces each.
3. **Modules:** merge, split, remove or add? Judge these candidates rather than assuming them: config/env (.env, TOML/YAML), sqlite or kv store, cache, logging, scheduling, text tables/templating, clipboard/notifications, process supervision, websocket/SSE, mail, diff/patch, date/duration parsing. For each, give the use case, a rough 3-line API, the cost (deps, startup ms, lines) and a verdict.
4. **Gaps between modules:** compositions that should be one pipe but are not.
5. **Defaults:** places where the default value is wrong for most scripts.

Rule: prefer deleting to adding. An addition must remove more call-site code than the surface it adds.
Output: PROPOSAL.md, with tables and one-liners, at most about 300 lines. End with a "do next" list of 10 items, each tagged Add/Remove/Merge/Change with effort S/M/L. Ask before writing code into lib/.

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
