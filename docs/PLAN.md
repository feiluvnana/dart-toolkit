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

### W4. M30: kill the whole process tree
In `lib/shell.dart`, add:
```dart
void _killTree(io.Process p) => io.Platform.isWindows
    ? io.Process.run('taskkill', ['/F', '/T', '/PID', '${p.pid}']).ignore()
    : p.kill(io.ProcessSignal.sigkill);
```
Use it for every `proc.kill(sigkill)`: the `_runLive` catch, and `filter`'s input-error, cancel, `!ok` and stdin-timeout paths. Test: a `.cmd` wrapper starts a long child; cancel the `filter`; check with `tasklist` that the grandchild pid is gone. Only ever kill pids we spawned.

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

## §2 Linux

### L1. M11: `Shell.open` with a foreground launcher keeps the script alive
The launcher's stdio is now released (fixed on POSIX), but `xdg-open` in generic mode runs `$BROWSER` in the foreground, and the plain `Process.start` child still holds the VM until it exits. In `lib/shell.dart` `open`, for the Linux branch start `['/bin/sh', '-c', 'xdg-open "\$1" </dev/null >/dev/null; echo "\$?"', '_', target]` with `mode: io.ProcessStartMode.detachedWithStdio`; read stdout with the existing 10 s timeout and parse the status: `127` → `ProcessException('xdg-open is not installed (install xdg-utils)')`, other non-zero → throw with the first 4 KB of stderr, no status by the timeout → handed off. Cancel both subscriptions. Check on Linux with `XDG_CURRENT_DESKTOP` unset and `BROWSER=firefox`: a script calling `Shell.open('https://example.com')` exits within 10 s and Firefox stays open.

### L3. `Shell.open`: the opened app dies of EPIPE after the launcher returns
`open` in `lib/shell.dart` cancels its stdout/stderr subscriptions after the launcher exits (or after 10 s), but the app `xdg-open` starts inherits those pipes; its next write to stderr (Firefox and Chromium log there) gets `EPIPE`/`SIGPIPE` and the app can die. Never hand the app our pipes: on Linux start `['/bin/sh', '-c', 'xdg-open "\$1" </dev/null >/dev/null 2>"\$2"', '_', target, errFile]` where `errFile` is a fresh file in `Directory.systemTemp.createTemp('dart_toolkit_open')`; after the exit (same 10 s timeout) read its first 4 KB for the non-zero-exit `ProcessException`, then delete the temp folder. Merge with L1 if done together (L1 already sends stdout to `/dev/null`). Check on Linux: `Shell.open('https://example.com')` in a script that exits at once; the browser stays open, and `strace -f -e trace=write -p <browser pid>` shows no `EPIPE`.

### L2. `Chrome.launch()` on linux-arm64 and windows-arm64
puppeteer's downloader throws `FormatException: Unknown 'linux_arm64' from Platform.version` (Docker on Apple Silicon, Raspberry Pi). In `lib/chrome.dart` `_cachedExecutable`, read the arch from `io.Platform.version` (`linux_arm64`/`windows_arm64`). On `linux_arm64` use the first of `chromium`, `chromium-browser`, `google-chrome-stable` found on PATH, else throw `UnsupportedError('no Chromium download for linux_arm64: apt install chromium, or pass path:')`. On `windows_arm64` throw the same error naming the platform (x64 emulation would need puppeteer's `src/` enum). Check on an arm64 box: `dart test test/chrome_test.dart` launches the system Chromium or fails with that message.
