# PLAN

## §1 Windows (run on a Windows PC; the Mac can't verify these)

Setup: `git pull`, `dart pub get`. After each step run `dart analyze` and the named test; commit as `<ID>: …`.

### W1. H18 check: Esc and arrows (code shipped, unverified)
1. In the VS Code terminal and in Windows Terminal, run `dart run tool/keylog.dart`. Press ↑ ↓ Esc. Expected bytes: `1b 5b 41`, `1b 5b 42`, `1b`.
2. Run a script with `print(await Console.choose('pick', ['a', 'b', 'c']));`. ↑/↓ move the selection, Enter picks, Esc cancels.
3. If step 1 never shows a `e0 ..` pair, delete the `if (b == 0xe0)` branch and `windowsKey` in `lib/src/terminal.dart`, plus their tests in `test/terminal_keys_test.dart` (the M2 Windows half).
4. Run `dart test test/console_test.dart -n "piped choose"` (H16, CRLF input).

### W2. H1: Chromium watchdog on Windows
In `lib/chrome.dart`, `Chrome._watchdog` returns null on Windows. Add a Windows branch:
```dart
io.Process.start('cmd', ['/c', 'findstr "^" >nul & taskkill /F /T /PID %CT_PID% >nul & rd /s /q "%CT_DIR%"'],
    environment: {'CT_PID': '$pid', 'CT_DIR': dir ?? ''});
```
Skip `rd` when there is no temp dir. Check that `dog.kill()` in `close()` ends the chain before `taskkill` runs. Port the H1 regression test: use `tasklist` instead of `pgrep` and `%TEMP%` instead of `TMPDIR`, and remove its Windows `skip:`. Verify with `dart test test/chrome_test.dart -n H1`.

### W3. M13: `.cmd`/`.bat` programs in `Shell.run`
In `lib/shell.dart`, the three start sites are `Process.run` (~46), the `Process.start` in `_runLive` (~78) and the start in `filter` (~326).
- Add `_resolveWindows(cmd)`: search PATH × PATHEXT (`.com .exe .bat .cmd`). If `cmd` has a directory part, try only the extensions. Return the first file that exists, else `cmd`.
- Add `_checkBatchArgs(exe, args)`: if `exe` ends in `.bat` or `.cmd`, throw `ArgumentError` when any argument contains one of ``" & | < > ^ % ! \r \n``.
- Route all three start sites through one helper that calls both.
- Tests (Windows only): `Shell.run(['npm', '--version'])` works; `Shell.run(['x.cmd', 'a&b'])` throws `ArgumentError`; a temp `echo.cmd` given a safe argument returns its output.

### W4. Kill the whole process tree on Windows
`lib/shell.dart` `_killTree(proc, signal)` reads the tree with `ps` on POSIX and signals it deepest first; on Windows it only calls `proc.kill`. Add the Windows branch at its top:
```dart
if (io.Platform.isWindows) {
  await io.Process.run('taskkill', ['/F', '/T', '/PID', '${proc.pid}']);
  return;
}
```
Every kill site (the run timeout, the exit hook, `filter`'s cancel and error paths) already goes through it. Test (Windows only): port `a timeout kills the grandchildren too` in `test/shell_test.dart` with `cmd /c "start /b ping -n 30 127.0.0.1 & ping -n 30 127.0.0.1"` and check with `tasklist /FI "IMAGENAME eq PING.EXE"` that none is left. Only ever kill pids we spawned.

### W5. M6: hide temp names
In `lib/fs.dart` `_atomicWrite` and `lib/archive.dart` unpack, run `attrib +h <tmp>` right after creating the temp file or folder. The M6 test is skipped on Windows because `Process.kill(sigint)` is unsupported there. Drive it with `GenerateConsoleCtrlEvent` or a manual Ctrl-C instead, and record the result here.

### W6. Checks only
- L11: `dart test test/fs_test.dart -n Link`. File symlinks need Developer Mode or admin. If `Link.create` fails, record that here.
- M29: `dart test test/archive_test.dart -n M29`.
- H14: Ctrl-Z suspend is POSIX only; check that the Windows Tui still gets Ctrl-C through `claimInterrupt`.

### W7. Console close runs the exit hooks
`lib/src/exit.dart` `_install` returns after SIGINT on Windows, but Dart delivers `sighup` there when the console window closes. Move the `sighup` block above `if (io.Platform.isWindows) return;`, and on Windows cut the per-hook timeout in `_handle` from 5 s to 2 s (Windows allows ~5 s after a close). Check: a script blocked in `await (slowReader > Fs.file('x'))` whose console window is closed leaves no `.x.tmp*` beside `x`.

### W8. UTF-8 glyphs in Windows Terminal and VS Code
`TerminalCaps.of` (`lib/src/terminal.dart`) decides `ascii` from `LC_ALL`/`LC_CTYPE`/`LANG`, which Windows rarely sets, so every Windows terminal gets the ASCII theme. Add a named parameter `bool? windows` (default `io.Platform.isWindows`) and, when true, set `ascii = !locale.contains('utf') && !(env.containsKey('WT_SESSION') || env['TERM_PROGRAM'] == 'vscode' || env.containsKey('ConEmuANSI'))`. Test in `test/terminal_keys_test.dart`: `TerminalCaps.of({'WT_SESSION': '1'}, hasTerminal: true, windows: true).ascii` is false, `TerminalCaps.of({}, hasTerminal: true, windows: true).ascii` is true. Then check by eye: Windows Terminal shows `━` bars, conhost shows `#`.

### W9. Rename retries for Defender and the indexer
`_renameOver` in `lib/fs.dart` retries 3 × 50 ms; `File.move`, `Dir.move`, `Link.create` and `_Unpacker._moveInto` (`lib/archive.dart`) do not retry. Add `Future<T> renameRetry<T>(Future<T> Function() op)` to `lib/src/posix.dart`: on Windows retry on `osError.errorCode` 5, 32 or 33 with waits of 20, 40, 80 … ms up to 1 s in total; elsewhere call `op()` once. Route the five sites through it. Test (Windows only): open the target from a second isolate for 300 ms, then `Fs.file(t).write('x')` succeeds after the handle closes.

### W10. Tui restore after `exit()` on Windows
`lib/src/tui/session.dart` `_startGuard` (a `sh` watchdog that restores the terminal when the process dies inside `Tui.run`) is POSIX only. On Windows check what `exit(3)` from a binding leaves in Windows Terminal and conhost: alternate screen, mouse reporting, VT input mode. If it is broken, add a `cmd` guard: start `cmd /c "findstr "^" >nul & <write the leave codes>"` with stdin from us, the same way as W2's watchdog, and write the leave codes with `powershell -c [Console]::Write(...)`. Record the result here.

### W11. Native tools on Windows (ffmpeg, ffprobe, 7zr)
`lib/src/tool.dart` pins Gyan's ffmpeg 9.0.2 essentials zip (`bin/ffmpeg.exe`, `bin/ffprobe.exe`) and 7-Zip's `7zr.exe` (7z only). With no ffmpeg/7z on PATH run `dart test test/image_test.dart test/video_test.dart test/archive_test.dart`. Check: the first run downloads into `%LOCALAPPDATA%\dart_toolkit\` once; the essentials build has every encoder the tests use (`libwebp`, `libaom-av1`, `libsvtav1`, `libx265`, `libvpx-vp9`, `libopus`, `libmp3lame`: run `ffmpeg -hide_banner -encoders`); if one is missing, switch the Windows entry to the full build (its sha256 is on the GitHub release) and record it here. RAR, bz2/zst, cab, ar and xar stay Dart-only or unsupported on Windows (7zr reads 7z only): the archive tests that need them skip there.

## §2 Linux

### L1. M11: `Shell.open` with a foreground launcher keeps the script alive
The launcher's stdio is now released (fixed on POSIX), but `xdg-open` in generic mode runs `$BROWSER` in the foreground, and the plain `Process.start` child still holds the VM until it exits. In `lib/shell.dart` `open`, for the Linux branch start `['/bin/sh', '-c', 'xdg-open "\$1" </dev/null >/dev/null; echo "\$?"', '_', target]` with `mode: io.ProcessStartMode.detachedWithStdio`; read stdout with the existing 10 s timeout and parse the status: `127` → `ProcessException('xdg-open is not installed (install xdg-utils)')`, other non-zero → throw with the first 4 KB of stderr, no status by the timeout → handed off. Cancel both subscriptions. Check on Linux with `XDG_CURRENT_DESKTOP` unset and `BROWSER=firefox`: a script calling `Shell.open('https://example.com')` exits within 10 s and Firefox stays open.

### L3. `Shell.open`: the opened app dies of EPIPE after the launcher returns
`open` in `lib/shell.dart` cancels its stdout/stderr subscriptions after the launcher exits (or after 10 s), but the app `xdg-open` starts inherits those pipes; its next write to stderr (Firefox and Chromium log there) gets `EPIPE`/`SIGPIPE` and the app can die. Never hand the app our pipes: on Linux start `['/bin/sh', '-c', 'xdg-open "\$1" </dev/null >/dev/null 2>"\$2"', '_', target, errFile]` where `errFile` is a fresh file in `Directory.systemTemp.createTemp('dart_toolkit_open')`; after the exit (same 10 s timeout) read its first 4 KB for the non-zero-exit `ProcessException`, then delete the temp folder. Merge with L1 if done together (L1 already sends stdout to `/dev/null`). Check on Linux: `Shell.open('https://example.com')` in a script that exits at once; the browser stays open, and `strace -f -e trace=write -p <browser pid>` shows no `EPIPE`.

### L2. `Chrome.launch()` on linux-arm64 (check only)
puppeteer is gone; `lib/src/chrome_find.dart` uses `path:`, the cached Chrome for Testing, then an installed Chrome/Chromium, and on an ABI with no Chrome for Testing build (linux-arm64, windows-arm64) throws `BrowserException('no Chrome found and no Chrome for Testing build for …')`. On an arm64 box (Docker on Apple Silicon, a Raspberry Pi) with `chromium` installed run `dart test test/chrome_test.dart`: it launches the system Chromium. Record the result here.

### L4. Process-tree kill with BusyBox `ps`
`_killTree` in `lib/shell.dart` runs `ps -A -o pid=,ppid=`. BusyBox (Alpine, many Docker images) has no `-A` and may reject `-o pid=,ppid=`, so the tree is empty and only the direct child dies. In an `alpine` container run `dart test test/shell_test.dart -n grandchildren`. If it fails, fall back to reading `/proc/*/stat` (field 4 is the ppid) when `ps` exits non-zero: list `/proc`, keep numeric names, parse `stat` after the last `)`.

### L5. `Dir.watch()` on Linux
`lib/fs.dart` `watch()` passes `recursive: !io.Platform.isLinux` because the SDK's inotify watcher is documented as not recursive there. On Linux run `dart test test/fs_test.dart -n "watch reports"`, then check by hand: a file written in a subfolder of the watched one is not reported. If the SDK does recurse on your version, drop the platform check and update the doc comment ("Linux watches this folder only").

### L6. Native tools on Linux (ffmpeg, ffprobe, 7zzs)
On x64 and arm64 Linux with no ffmpeg/7zz on PATH run `dart test test/image_test.dart test/video_test.dart test/archive_test.dart`: Martin Riedl's static ffmpeg and 7-Zip's `7zzs` download once into `$XDG_CACHE_HOME/dart_toolkit/` (or `~/.cache`). Record the result here.

## §3 Open

### O1. `Console.ask(timeout:)` on piped stdin keeps the VM alive
An ask abandoned by a timeout leaves an isolate blocked in `readLineSync`, and the VM waits for it even after `kill()`. Fixing it needs stdin read as a stream with pushback, which gives up "never reads past its line" for children sharing stdin. Decide whether that trade is worth it before coding.
