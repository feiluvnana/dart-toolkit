# Plan · what is left

What a Mac could not finish. The rules are in `CONVENTIONS.md`.

## 0 · keybox, live

Run `dart run example/keybox/keybox.dart` from a network that reaches `key.visualarts.gr.jp` and
`downloads.khinsider.com` (from the Mac the first timed out and the second answered 403 to a plain
client). It should download everything, resume after ^C (one `⚠` line), skip what exists
(`Done(fresh: false)`), and zip the box atomically. Fix what it finds, each fix with a test.

## 1 · Windows (on a Windows PC)

Nothing has run on Windows. Needs the Rust MSVC toolchain, `nasm`, PowerShell 7 and `make`.
`tool/bench/baseline.json` holds macOS numbers, so never pass `--check` on Windows.

0. **Native libraries.** `make native` builds both DLLs (the Mac's cross-build fails in the C
   dependencies, mozjpeg and unrar). `make native-release` on the PC uploads the Windows assets
   (and their `.sha256`) to the release of the same sources.
1. **Baseline.** Run `make`. Sort each failure as a library bug, a POSIX-only test (a Windows twin,
   else `testOn: '!windows'` with the reason), or flaky. Then review the tests skipped on Windows
   the same way (links and modes in `fs_test`, the link-and-mode save tests in the formats tests,
   process quoting and tree stops in `process_test`, zip times in `archive_test`).
2. **Processes.**
   - The one cmd.exe launcher: the line rides in `DART_TOOLKIT_COMMAND`
     (`cmd.exe /d /v:off /c %DART_TOOLKIT_COMMAND%`). Check `.bat`/`.cmd` in paths with spaces,
     argument quoting, `%` inside arguments, built-ins (`dir`, `echo`), `Shell.sh` with operators
     and `%NAME%`.
   - A live `Shell.run(r'C:\tools\ffmpeg.exe -i x')` (the splitter itself is tested on the Mac).
   - `which`: `PATH`/`PATHEXT`, a name whose extension is not in `PATHEXT`, a `PATH` from the
     call's `env`.
   - `taskkill /T /F` tree stops; assign every child (Chrome included) to the kill-on-close Job
     Object at creation, not after start.
   - `Shell.interact`'s ^C handling; `Cli` leaves ^C to an interactive child.
   - Win32 5/193 → exit 126, 2/3 → 127.
3. **Detached jobs.** The runner start, file locking when adopting `local/<pid>.json`, and
   `runner.json` (no permission restriction beyond the per-user `%APPDATA%`).
4. **Atomic writes and renames.** `FileBridge.rename` retries over a held target (error 5 or 32)
   on the write, merge, rename and copy paths, and for `Table.writer`/`save`. Check with Explorer
   or an antivirus scanner holding the file, including in-place `compress` (the original is held
   in `.compressing-<token>/` beside it; the Recycle Bin records that folder as its origin).
5. **Files.**
   - Trash: the refusal for non-fixed drives (`GetDriveTypeW`), the Recycle Bin check
     (`SHQueryRecycleBinW`) and `FOF_WANTNUKEWARNING`.
   - `touch()` on a folder throws `UnsupportedError`.
   - Delete retries a read-only file, or a tree holding one, after making it writable (error 5).
   - `free()` on a mount-point folder; `lock()` contention (code 33) and the claims; `tk_copy_file`'s
     read/write loop for files over 64 MiB; staging folders holding read-only files;
     `changes()` event semantics.
   - Zip times read and written as local time (`native/src/archive.rs`).
6. **Text from Windows programs.** The Windows-1252 fallback and UTF-16 LE byte-order marks on real
   Notepad and Excel files; labels splitting paths on `\`.
7. **Torrent.** Session folders and stream reads; the engine error mapping (OS codes 2/3 for a
   missing path, bind errors matched by English text).
8. **Chrome and downloads.** `DART_TOOLKIT_CHROME`, then `chrome.exe`/`msedge.exe` under
   `LOCALAPPDATA` and Program Files; a profile held when `<profile>\lockfile` cannot be opened
   (error 32); `OpenProcess`+`GetExitCodeProcess` for "alive"; retry erasing a temporary profile;
   the download folder given with backslashes; without the reaper a launched Chrome dies only on
   `close()`; `connect(start:)`'s default profile in `%APPDATA%`. A download's final rename and the
   Chrome download move use `FileBridge.rename` and fall back to copy-then-rename across volumes.
9. **Terminal.**
   - `_WinConsole`: raw VT input (`SetConsoleMode`), else `ReadConsoleInputW` on a helper isolate;
     stderr VT output; both modes restored in `close`; `unicode` for code page 65001; ^C raised
     once, not passed on as a key.
   - Resizes are not watched (no SIGWINCH): the next frame measures; SIGTERM is not watched.
   - The picker is still numbered input on Windows.
   - The kitty keyboard query and the cursor position report (inline mouse) in Windows Terminal.
   - `stderr.supportsAnsiEscapes` decides the live region.
   - Check redraw, colour, `NO_COLOR`, redirection (`> out.txt` holds no escapes), `secret` and
     `-q` in Windows Terminal, conhost, PowerShell 7 and VS Code, and note the results.
10. **Required.** When Windows is green, state Windows support in README.

---

**Not to re-propose.** These were measured or argued and declined: user-agent rotation, GraphQL,
OpenGraph/JSON-LD helpers, websockets; autoscaled concurrency, bandwidth limits, an `$EDITOR`
prompt, OSC 52, notifications; extensions on `Future<Doc>`; a default warning for crawl failures;
double-buffering the Tui frame, AVIF/JPEG XL/HEIC, torrent web seeds/MSE/v2, HTTP/2.

When both sections are done, delete this file. The record is CHANGELOG and CONVENTIONS.
