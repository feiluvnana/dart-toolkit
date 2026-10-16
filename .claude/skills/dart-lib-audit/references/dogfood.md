# DOGFOOD lens (opt-in: `/dart-lib-audit dogfood`)

Find friction by building real things on the library.

Write 5 small but real scripts in projects/_dogfood/ (never committed; delete it when done), each a task people actually automate. Run them against loopback servers. For example:
1. Mirror a docs site to disk with assets, resumable, with a progress bar.
2. A CLI that watches a folder, hashes new files and uploads changed ones over HTTP with retries.
3. A Tui dashboard that runs shell commands in parallel and shows live output and status.
4. Scrape a paginated listing into JSON with dedupe and a cache, then render a summary table.
5. Download a release archive, verify its checksum, unpack it and run a binary from it.

Use only dart_toolkit and dart:core. Whenever you reach for dart:io, raw streams, a try/catch, a manual loop or a workaround, log it: the task, what you wrote, what you wished you could write, the module.

Never write DOGFOOD.md or any other log file. The friction log (ranked by hits and lines wasted) and each script's line count go in the chat report; each friction becomes a finding in docs/AUDIT.md under the ERGONOMIC or FEATURE lens.

After dart-lib-fix applies the top items, rerun the scripts and report the line counts again.
