# Bugs and performance

Find and fix defects and slow paths across lib/. Work module by module, with read-only investigation first.

Look for:
- **Correctness:** wrong results, edge cases (empty, huge, unicode, CRLF, partial reads, redirects, timeouts), and error paths that hide or misreport the cause.
- **Liveness:** anything that keeps the VM alive after the work is done (sockets, timers, stdin listeners, child processes, signal watchers), deadlocks, hangs on cancel, and orphaned children.
- **Resources:** unclosed files, sockets or responses, temp files left behind (including on Ctrl-C), and memory that grows with input size where it should stream.
- **Speed:** hot loops, repeated work, needless copies, regex in loops, sync I/O on hot paths, startup cost of imports, and isolate overhead.
- **Concurrency:** races between futures, re-entrancy, and pause/cancel semantics on streams.

Method: prove each finding with a scratch script, a loopback server, a pty driver or an RSS/timing measurement. Mark it Verified or Plausible. Fix only Verified findings: one commit each, with a regression test (tests that check a process exits must spawn a child). Give performance fixes an A/B number in the commit message.
Report: a table of ID, severity, module, one-line problem, fix commit or "skipped: why". Put anything you cannot verify on this Mac into PLAN.md (Windows §1, Linux §2) with exact steps.

## Context (same in every prompt)
- dart_toolkit, branch master: a Dart scripting toolkit. VISION.md is the intended API; lib/*.dart is the public surface (lib/src is private).
- examples/ has one file per module plus combos; projects/rawfree.dart is a real Tui app built on it; PLAN.md holds Windows and Linux handoffs.
- Priorities: speed (runtime, then startup) > call-site brevity = discoverability > the rest.
- Every module works alone and composes: `Reader | Pipe > Writer`, Future mirrors (no inner `await`), actions return the receiver, readings are methods, named params over chains.
- Names: short, one word when it reads one way, the same word for the same idea in every module (see VISION §1).
- Pure Dart plus pub packages; no native code, no codegen, no sync twins. No backward compatibility: rename, merge or delete freely.
- Tui is alternate-screen only and has no colour by default (`accent:` opts in); scrollback output belongs to Console.
- Every bug fix gets a regression test. Before each commit: `dart analyze lib test examples projects tool` is clean and the full `dart test` passes.
- One commit per finding, message `<area>: <imperative summary>`, no trailers, never push. Do not commit prompt output files unless asked.
- Never signal pid -1 or 0, or any process you did not spawn.
- Measure speed claims with back-to-back A/B runs; this machine drifts ±80 ms.
