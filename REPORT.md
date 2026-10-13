# REPORT.md — work left vs VISION.md v2

§§1–14 and 16–17 of the review are fixed, each with a regression test. §15, the state-driven
`tui`, is implemented (VISION §4.12), tested (`test/tui_test.dart`, `test/tui_pty/`), and proven
by `example/rawfree.dart` (the download manager) and `example/agent.dart` (the Claude Code loop).
What is still open:

## tui

- [SPEC-L] `example/rawfree.dart` UI part is ~220 lines against the ≤ 150 target. About 60 of
  them are the queue worker and page fetch. Find what the library should own (a `Pick` edit
  such as add/remove/where would delete `_enqueue`/`_remove`/`clear done`) before cramming lines.
- [SPEC-L] The status-row bar draws `━━╸──` but `Console.bar` draws `█░`; pick one glyph set for
  both (§15.3 says the bar lays out like `Console.bar`).
- [SPEC-L] `markdown` puts no blank line between blocks.
- [TEST] No pty test for Ctrl-Z suspend/resume.
- [VERIFY] Not checked in a real terminal yet: OSC 52 `copy`, `notify` (OSC 9/777), `shift+tab`
  and kitty `shift+enter`, and whether any terminal echoes `CSI < u` (the kitty-protocol pop) as
  a stray `u` on exit (pyte does).
- [VERIFY] rawfree against the live site: search worked; chapter loading and downloads were run
  against a stubbed API because the site was down (`Error establishing a Redis connection`).
