# PLAN

## §1 Windows (run on a Windows PC; the Mac can't verify these)

Setup: `git pull`, `dart pub get`. After each step run `dart analyze` and the named test; commit as `<ID>: …`.

### W1. H18 check: Esc and arrows (code shipped, unverified)
1. In the VS Code terminal and in Windows Terminal, run `dart run tool/keylog.dart`. Press ↑ ↓ Esc. Expected bytes: `1b 5b 41`, `1b 5b 42`, `1b`.
2. Run a script with `print(await Console.choose('pick', ['a', 'b', 'c'], (s) => s));`. ↑/↓ move the selection, Enter picks, Esc cancels.
3. If step 1 never shows a `e0 ..` pair, delete the `if (b == 0xe0)` branch and `windowsKey` in `lib/src/keys_decode.dart`, plus their tests in `test/terminal_keys_test.dart` (the M2 Windows half).
4. Run `dart test test/console_test.dart -n "piped choose"` (H16, CRLF input).

### W2. H1: Chromium watchdog on Windows
In `lib/chrome.dart`, `Chrome.launch` skips `_watchdog` on Windows (the `!io.Platform.isWindows` on the `final dog =` line). Add a Windows branch to `_watchdog` and drop that condition:
```dart
io.Process.start('cmd', ['/c', 'findstr "^" >nul & taskkill /F /T /PID %CT_PID% >nul & rd /s /q "%CT_DIR%"'],
    environment: {'CT_PID': '$pid', 'CT_DIR': dir ?? ''});
```
Skip `rd` when there is no temp dir. Check that `io.Process.killPid(dog.pid)` in `close()` ends the chain before `taskkill` runs, and that `Browser._gone` (Chromium exited on its own: the CDP connection ended without `close()`) kills it too, so it never `taskkill`s a reused pid; port `dart test test/chrome_test.dart -n S11` (`tasklist` for `ps`). Then B8 (an unclosed browser keeps the script alive): POSIX starts Chrome `detached` with its stderr in a log file and reads the CDP pipe in a helper isolate whose port is unref'd while idle (`Cdp.pipe`); Windows still starts it attached with piped stderr and talks over the debugging-port WebSocket, which holds the VM. Port the same shape (detached start, the WebSocket read in a helper isolate behind a `RawReceivePort` with `keepIsolateAlive` toggled by `Cdp.hold`), then run `dart test test/chrome_test.dart -n B8` without its Windows `skip:`. Port the H1 regression test: use `tasklist` instead of `pgrep` and `%TEMP%` instead of `TMPDIR`, and remove its Windows `skip:`. Verify with `dart test test/chrome_test.dart -n H1`.

### W3. M13: `.cmd`/`.bat` programs in `Shell.run`
In `lib/shell.dart`, the two start sites are the `io.Process.start` in `Shell.run` and the one in `_Filter.transform` (`Shell.filter`); `ShellUtils.open` (`lib/src/shell_utils.dart`) starts the OS launcher and stays as it is.
- Add `_resolveWindows(cmd)`: search PATH × PATHEXT (`.com .exe .bat .cmd`). If `cmd` has a directory part, try only the extensions. Return the first file that exists, else `cmd`.
- Add `_checkBatchArgs(exe, args)`: if `exe` ends in `.bat` or `.cmd`, throw `ArgumentError` when any argument contains one of ``" & | < > ^ % ! \r \n``.
- Route both start sites through one helper that calls both.
- Tests (Windows only): `Shell.run(['npm', '--version'])` works; `Shell.run(['x.cmd', 'a&b'])` throws `ArgumentError`; a temp `echo.cmd` given a safe argument returns its output.

### W4. Kill the whole process tree on Windows
`lib/shell.dart` `_killTree(proc, signal)` reads the tree with `ps` on POSIX and signals it deepest first; on Windows it only calls `proc.kill`. Add the Windows branch at its top:
```dart
if (io.Platform.isWindows) {
  await io.Process.run('taskkill', ['/F', '/T', '/PID', '${proc.pid}']);
  return;
}
```
Put it after the `_reaped` check, which must stay first (a reaped pid may belong to someone else). Every kill site (the run timeout, a cancel, the exit hook, `filter`'s cancel and error paths) already goes through it. Test (Windows only): port `a timeout kills the grandchildren too` in `test/shell_test.dart` with `cmd /c "start /b ping -n 30 127.0.0.1 & ping -n 30 127.0.0.1"` and check with `tasklist /FI "IMAGENAME eq PING.EXE"` that none is left. Only ever kill pids we spawned.

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
`_renameOver` in `lib/fs.dart` retries 3 × 50 ms; `File.move`, `Dir.move`, `Link.create` and `_Extraction._moveInto` (`lib/archive.dart`) do not retry. Add `Future<T> renameRetry<T>(Future<T> Function() op)` to `lib/src/posix.dart`: on Windows retry on `osError.errorCode` 5, 32 or 33 with waits of 20, 40, 80 … ms up to 1 s in total; elsewhere call `op()` once. Route the five sites through it, plus the renames into place in `lib/src/tool.dart` `_download` (the sibling tool), `lib/src/media.dart` `replaceIfSmaller`, `lib/src/fetch.dart` `_app` (the unpacked Chrome folder) and `lib/http.dart` `_deliver` (both `part.rename(path)`: a resumed `.part` into place). Test (Windows only): open the target from a second isolate for 300 ms, then `Fs.file(t).write('x')` succeeds after the handle closes.

### W10. Tui restore after `exit()` on Windows
`lib/src/tui/session.dart` `_startGuard` (a `sh` watchdog that restores the terminal when the process dies inside `Tui.run`) is POSIX only. On Windows check what `exit(3)` from a binding leaves in Windows Terminal and conhost: alternate screen, mouse reporting, VT input mode. If it is broken, add a `cmd` guard: start `cmd /c "findstr "^" >nul & <write the leave codes>"` with stdin from us, the same way as W2's watchdog, and write the leave codes with `powershell -c [Console]::Write(...)`. Record the result here.

### W11. Native tools on Windows (ffmpeg, ffprobe, 7zr)
`lib/src/tool.dart` pins Gyan's ffmpeg 9.0.2 essentials zip (`bin/ffmpeg.exe`, `bin/ffprobe.exe`) and 7-Zip's `7zr.exe` (7z only). With no ffmpeg/7z on PATH run `dart test test/image_test.dart test/video_test.dart test/archive_test.dart`. Check: the first run downloads into `%LOCALAPPDATA%\dart_toolkit\` once; the essentials build has every encoder the tests use (`libwebp`, `libaom-av1`, `libsvtav1`, `libx265`, `libvpx-vp9`, `libopus`, `libmp3lame`: run `ffmpeg -hide_banner -encoders`); if one is missing, switch the Windows entry to the full build (its sha256 is on the GitHub release) and record it here. RAR, bz2/zst, cab, ar and xar stay Dart-only or unsupported on Windows (7zr reads 7z only): the archive tests that need them skip there.

### W12. `ShellUtils.which` prefers `npm.cmd` to the `npm` shim
`which` in `lib/src/which.dart` (behind `ShellUtils.which`, `tool()` and chrome's Linux lookup) tries `['', ...PATHEXT]`, so on Windows the bare name wins: npm's extensionless `sh` shim beats `npm.cmd`, and the bare file cannot run there. On Windows try the PATHEXT extensions first and the bare name last (or only when it already has an extension: `program.contains('.')`). Check: `await Shell.which('npm')` ends in `npm.cmd`, `await Shell.which('ffmpeg')` ends in `.exe`, `await Shell.which('ffmpeg.exe')` finds the same file.

### W13. Chrome for Testing on Windows arm64
`testingPlatform()` in `lib/src/chrome_find.dart` maps `Abi.windowsArm64` to nothing, so with no Chrome installed a Windows arm64 PC throws. Chrome for Testing has no arm64 Windows build, but `win64` runs emulated: add `Abi.windowsArm64 => 'win64'`. Check on a Windows arm64 PC with no Chrome: `dart test test/chrome_test.dart` downloads `win64` once and passes. CDP over a pipe (`--remote-debugging-pipe`) is POSIX only; Windows keeps the TCP port, so check the port is bound to `127.0.0.1` only (`netstat -ano | findstr <chrome pid>`).

### W14. `Link.resolve` on a broken chain (B27)
`Link.resolve()` in `lib/fs.dart` returns null only for a broken link and throws on anything else (permission denied); which errors mean broken comes from `_broken`, which is empty on Windows, so only a `PathNotFoundException` is null there. On Windows (Developer Mode, so links can be made) run: `mklink loop loop`, `mklink /D dirlink nofolder`, and a link to `file.txt\x`; then `await Fs.link('loop').resolve()` and the others. Each should be null: if one throws, add its `osError.errorCode` (likely 1921 ERROR_CANT_RESOLVE_FILENAME, 3 path not found, 267 ERROR_DIRECTORY) to the Windows set and run `dart test test/fs_test.dart -N B27`.

### W15. `.cmd` shims and `rundll32` (S10)
`tool()` (`lib/src/tool.dart` `_locate`) takes the first `which` hit for ffmpeg/ffprobe/7z, which on Windows can be a `.cmd`/`.bat` shim (Scoop, Chocolatey): cmd.exe parses its arguments, so a file name with `&` or `%` runs commands. And `ShellUtils.open` (`lib/src/shell_utils.dart`) starts a bare `rundll32`, which Windows looks up in the current folder first. Fix: in `_locate`, skip a hit whose extension is `.bat` or `.cmd` (the pinned download follows); in `Shell.open` use `'${io.Platform.environment['SystemRoot'] ?? r'C:\Windows'}' r'\System32\rundll32.exe'`. Check: with an `ffmpeg.cmd` earlier on PATH than a real `ffmpeg.exe` (or none), `await Video.open(...)` uses the `.exe` or the pinned download; `Shell.open('https://example.com')` run from a folder holding a planted `rundll32.exe` (a copy of `whoami.exe`) does not run it. Coordinate with W3/W12 (PATHEXT order).

### W16. Prompts leave the VM alive after `main` (P1)
On POSIX the terminal reader is a `cat` child that dies with our pipe; on Windows `lib/src/terminal.dart` reads `io.stdin.asBroadcastStream()` (`stdinBytes`, and the `_stdinFallback` listener in the tty reader), which is never released. Check: a script that calls `Console.choose`, `Console.key`, `Console.ask(timeout:)` or `Tui.run` once and returns from `main` exits at once in Windows Terminal and conhost (time it: `Measure-Command { dart run x.dart }`). The mechanism is proven on macOS: `sleep 6 | dart fallback.dart` ran 6 s. If it hangs, read the console through a child that dies with our pipe, as the POSIX `cat` does (`cmd /c "more"` or a tiny `powershell -c` reader), and record what worked here.

### W17. Case-insensitive environment in `Shell.run(env:)` (P4)
`_resolveEnv` (`lib/shell.dart`) merges `env` into `Platform.environment` by exact key, but Windows env names are case-insensitive: `env: {'Path': null}` leaves `PATH` set, and `{'path': 'x'}` adds a second entry. On Windows, match keys case-insensitively (remove every key whose `toUpperCase()` equals the given one before setting it). Test (Windows only): `Shell.run(['cmd', '/c', 'echo %PATH%'], env: {'Path': null})` prints `%PATH%`. Also check how `Shell.run(['cmd', '/c', 'echo é']).text()` decodes: if it is mojibake, the console code page (`chcp`) is not UTF-8; record the result and whether `cmd /u` or `chcp 65001` is the fix.

### W18. Idle Tui misses resizes on Windows (P7)
`lib/src/tui/session.dart` redraws on resize through `exit.onResize` (`SIGWINCH`), which Windows does not have, so an idle Tui keeps its old layout until a key arrives. On Windows, while `Tui.run` is active, poll `io.stdout.terminalColumns`/`terminalLines` every 250 ms in the session (a `Timer.periodic` started in `_enter`, cancelled in `_leave`; only when idle, since a busy frame reads the size anyway) and fire the same path as `exit.onResize`. Check: resize the Windows Terminal window while an idle Tui shows a box; it redraws within a quarter second.

## §2 Linux

### L1. M11: `ShellUtils.open` with a foreground launcher keeps the script alive
The launcher's stdio is now released (fixed on POSIX), but `xdg-open` in generic mode runs `$BROWSER` in the foreground, and the plain `Process.start` child still holds the VM until it exits. In `lib/src/shell_utils.dart` `open`, for the Linux branch start `['/bin/sh', '-c', 'xdg-open "\$1" </dev/null >/dev/null; echo "\$?"', '_', target]` with `mode: io.ProcessStartMode.detachedWithStdio`; read stdout with the existing 10 s timeout and parse the status: `127` → `ProcessException('xdg-open is not installed (install xdg-utils)')`, other non-zero → throw with the first 4 KB of stderr, no status by the timeout → handed off. Cancel both subscriptions. Check on Linux with `XDG_CURRENT_DESKTOP` unset and `BROWSER=firefox`: a script calling `Shell.open('https://example.com')` exits within 10 s and Firefox stays open.

### L3. `ShellUtils.open`: the opened app dies of EPIPE after the launcher returns
`open` in `lib/src/shell_utils.dart` cancels its stdout/stderr subscriptions after the launcher exits (or after 10 s), but the app `xdg-open` starts inherits those pipes; its next write to stderr (Firefox and Chromium log there) gets `EPIPE`/`SIGPIPE` and the app can die. Never hand the app our pipes: on Linux start `['/bin/sh', '-c', 'xdg-open "\$1" </dev/null >/dev/null 2>"\$2"', '_', target, errFile]` where `errFile` is a fresh file in `Directory.systemTemp.createTemp('dart_toolkit_open')`; after the exit (same 10 s timeout) read its first 4 KB for the non-zero-exit `ProcessException`, then delete the temp folder. Merge with L1 if done together (L1 already sends stdout to `/dev/null`). Check on Linux: `Shell.open('https://example.com')` in a script that exits at once; the browser stays open, and `strace -f -e trace=write -p <browser pid>` shows no `EPIPE`.

### L2. The installed Chromium is used on linux-arm64 (check only)
Chrome for Testing has no linux-arm64 build, so `lib/src/chrome_find.dart` takes an installed Chrome/Chromium (the first on PATH), and throws `BrowserException('no Chrome found and no Chrome for Testing build for …')` without one. On an arm64 box (Docker on Apple Silicon, a Raspberry Pi) with `chromium` installed run `dart test test/chrome_test.dart`: it launches the system Chromium over the CDP pipe. Record the result here.

### L4. Process-tree kill with BusyBox `ps`
`_killTree` in `lib/shell.dart` runs `ps -A -o pid=,ppid=`. BusyBox (Alpine, many Docker images) has no `-A` and may reject `-o pid=,ppid=`, so the tree is empty and only the direct child dies. In an `alpine` container run `dart test test/shell_test.dart -n grandchildren`. If it fails, fall back to reading `/proc/*/stat` (field 4 is the ppid) when `ps` exits non-zero: list `/proc`, keep numeric names, parse `stat` after the last `)`.

### L6. Native tools on Linux (ffmpeg, ffprobe, 7zzs)
On x64 and arm64 Linux with no ffmpeg/7zz on PATH run `dart test test/image_test.dart test/video_test.dart test/archive_test.dart`: Martin Riedl's static ffmpeg and 7-Zip's `7zzs` download once into `$XDG_CACHE_HOME/dart_toolkit/` (or `~/.cache`). Record the result here.

### L7. Chrome as root and the snap Chromium
In a Docker container running as root, Chromium refuses to start without `--no-sandbox`; `Chrome.launch` in `lib/chrome.dart` passes no such flag. Add `if (io.Platform.isLinux && _isRoot()) '--no-sandbox'` to the launch flags, where `_isRoot()` runs `id -u` once and compares with `0` (no FFI). The snap Chromium (Ubuntu desktop) has a private `/tmp`, so the download folder (`Browser._downloadFolder`, `systemTemp`) and the upload staging folder (`Page` upload, `dart_toolkit_up`) are invisible to it: when the executable path starts with `/snap/`, create both under `~/snap/chromium/common/dart_toolkit/` instead. Check: `docker run --rm -it -v $PWD:/src -w /src dart:stable dart test test/chrome_test.dart` with `chromium` installed in the image (as root), and on an Ubuntu desktop with only the snap: the download and upload tests pass.

## §3 Open (any machine)

### O2. Archive decoders off the startup path (measured, not done)
`lib/archive.dart` imports the 7z, RAR and xz decoders, ~50 ms of JIT startup for every script that imports `archive` (2026-10-16: stubbing them out gave 565 vs 614 ms medians, 9 runs × 3). A `spawnUri` worker would drop them from startup, but a URI isolate compiles from source on every spawn: 240–380 ms per 7z/RAR/xz extraction (the shared helpers already sit in `lib/src/unpack.dart` for such a worker), and a compiled exe cannot spawn one at all. Deferred imports save nothing under JIT. Revisit only if the SDK can spawn a precompiled kernel cheaply.

### O3. A regression test for a Tui whose terminal input dies
`_inputLost` in `lib/src/tui/session.dart` ends `Tui.run` with `StdinException('the TUI lost its terminal input (…): no keys, no Ctrl-C')` when the tty reader's stream ends (it used to hang with ISIG off). It shipped without a test.
1. In `test/tui_pty/probe.dart` add a mode `inputlost`: `Tui.run<int>(0, (s, app) => Screen((r) => r.write('up')))` inside `try`/`on StdinException catch (e)`; before it, start `Timer(const Duration(milliseconds: 500), …)` that runs `pgrep -P $pid` (`pid` from `dart:io`), and for each child pid whose `ps -o args= -p <child>` contains `cat -u /dev/tty` or `cat >/dev/null`, also `pgrep -P <child>` for its own children, then `Process.killPid` every pid found with `SIGKILL`. Only the probe's own children: never signal pid -1, 0 or anything it did not start. In the `catch`, write `lost: ${e.message}` to the log and return.
2. In `test/tui_pty_test.dart` add a test like the existing `drive.py` ones (`--size 24 80`, mode `inputlost`, `TERM=xterm-256color`): the driver's exit code is 0 within 20 s and the log contains `lost: the TUI lost its terminal input`.
3. Check: `dart test test/tui_pty_test.dart -n "input"` passes; with the `onDone:`/`onError:` lines in `_listenStdin` removed it times out (then put them back).

### O4. Watch the 7-Zip load-only failure (T14, half closed)
The audit saw `archive_test.dart` "7-Zip reads .tar.bz2, .tar.zst and ar for us" fail only under the full suite; the Chrome half was a real race (fixed in 593cd058), this one never failed again in ~20 full runs. Run `for i in 1 2 3 4 5; do dart test -r expanded > /tmp/run$i.txt 2>&1; grep "\[E\]" /tmp/run$i.txt; done`. If it fails, the log names the step: two parallel tests that run 7-Zip share `~/Library/Caches/dart_toolkit/7zip-26.04` (read only) and each test's own `tmp` folder, so look at `Shell.filter`'s stdin and the `-si` pipe first. Record the result here; with five clean runs, delete this item.

### O5. Prune superseded pinned builds
Pins live in versioned folders of the user cache (`dart_toolkit/chrome/155.0.8059.84/…`, `7zip-26.04`, `ffmpeg-9.0.2`); a bump leaves the old one (Chrome for Testing is ~150 MB) and the unversioned `chrome/chrome-mac-arm64`, `chrome/chrome-headless-shell-mac-arm64` from before the pin stay forever.
1. In `lib/src/chrome_find.dart` `_testingChrome`, after a successful download (inside the lock, after the `exe` check), list `p.join(userCacheDir(), 'dart_toolkit', 'chrome')` and delete every entry that is not `_version` and does not end in `.lock` (`Directory.delete(recursive: true)`, errors ignored: another process may still run an old build).
2. In `lib/src/tool.dart` `_download`, after the binary lands, delete the sibling folders of `_home(t)` that start with the same prefix (`7zip-` or `ffmpeg-`) and are not `_home(t)` itself.
3. Test in `test/tool_test.dart`: with `HOME` pointed at a temp folder in a child script (`runDart(env: {'HOME': …})`), create `…/dart_toolkit/chrome/1.0/x` and `…/chrome/chrome-mac-arm64/x`, call the pruning helper (factor it out as `pruneOld(String parent, String keep)` in `lib/src/cache.dart` so the test needs no download) and check both are gone and `keep` stays.
4. Check: `dart analyze`, `dart test test/tool_test.dart`.
