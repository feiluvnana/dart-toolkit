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

## §2 Linux

### L1. M11: `Shell.openInDefaultApp` keeps the script alive
In `lib/shell.dart` (~176), replace `['xdg-open', target]` with `['/bin/sh', '-c', 'xdg-open "$1" </dev/null >/dev/null 2>&1', '_', target]`. Treat `sh` exit 127 as "xdg-open missing". Verify on Linux: a script that calls `openInDefaultApp` exits while the app stays open.
