#!/usr/bin/env python3
"""Run a command under a real pty, feeding input bytes and signals.

Usage: drive.py --size ROWS COLS [--ready TEXT] [--feed DELAY_SECS PY_ESCAPED_BYTES]...
                [--signal DELAY_SECS NAME]... [--resize DELAY_SECS ROWS COLS]... -- CMD...

Delays count from the moment the app is ready: its output first contains
`--ready` (default: the TUI's `CSI ? 2004 h`, written once raw mode and the
signal handlers are in place), so a slow start under load never eats input. Captured terminal output goes to stdout;
the child's exit status goes to stderr as `exit=N` (negative: killed by
that signal). Signals go only to the child this script forked."""
import os
import pty
import sys
import time
import select
import fcntl
import signal
import termios
import struct



def main():
    argv = sys.argv[1:]
    rows, cols = 24, 80
    ready_mark = b'\x1b[?2004h'
    events = []  # (delay_secs, bytes | signal number)
    i = 0
    while i < len(argv):
        if argv[i] == '--size':
            rows, cols = int(argv[i + 1]), int(argv[i + 2])
            i += 3
        elif argv[i] == '--feed':
            data = argv[i + 2].encode('utf-8', 'surrogateescape').decode('unicode_escape').encode('latin1')
            events.append((float(argv[i + 1]), data))
            i += 3
        elif argv[i] == '--ready':
            ready_mark = argv[i + 1].encode('utf-8')
            i += 2
        elif argv[i] == '--resize':
            events.append((float(argv[i + 1]), ('resize', int(argv[i + 2]), int(argv[i + 3]))))
            i += 4
        elif argv[i] == '--signal':
            events.append((float(argv[i + 1]), getattr(signal, 'SIG' + argv[i + 2])))
            i += 3
        elif argv[i] == '--':
            i += 1
            break
        else:
            i += 1
    cmd = argv[i:]
    events.sort(key=lambda e: e[0])

    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(cmd[0], cmd)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
    out = b''
    start = time.time()
    ready = None  # time the app became ready
    pending = list(events)
    status = None
    try:
        # Budget: 30 s to get ready, then 25 s to run.
        while True:
            now = time.time()
            if ready is None and ready_mark in out:
                ready = now
            if ready is None and now - start > 30:
                break
            if ready is not None and now - ready > 25:
                break
            while ready is not None and pending and pending[0][0] <= now - ready:
                _, what = pending.pop(0)
                try:
                    if isinstance(what, bytes):
                        os.write(fd, what)
                    elif isinstance(what, tuple):
                        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', what[1], what[2], 0, 0))
                        os.kill(pid, signal.SIGWINCH)
                    else:
                        os.kill(pid, what)
                except OSError:
                    pass
            timeout = 0.1
            if ready is not None and pending:
                timeout = min(0.5, max(0.02, pending[0][0] - (now - ready)))
            r, _, _ = select.select([fd], [], [], timeout)
            if r:
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    chunk = b''
                out += chunk
            done, st = os.waitpid(pid, os.WNOHANG)
            if done == pid:
                status = st
                # Drain what is left, then stop.
                while True:
                    r, _, _ = select.select([fd], [], [], 0.2)
                    if not r:
                        break
                    try:
                        chunk = os.read(fd, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    out += chunk
                break
    finally:
        # EOF on the pty usually means the child is exiting: give it a moment.
        deadline = time.time() + 2
        while status is None and time.time() < deadline:
            try:
                done, st = os.waitpid(pid, os.WNOHANG)
                if done == pid:
                    status = st
            except ChildProcessError:
                break
            if status is None:
                time.sleep(0.05)
        if status is None:
            # The pty closing below sends SIGHUP, which would hide a hang.
            sys.stderr.write('child did not exit on its own\n')
        try:
            os.close(fd)
        except OSError:
            pass
        if status is None:
            try:
                _, status = os.waitpid(pid, 0)
            except (OSError, ChildProcessError):
                pass
    if status is not None:
        code = os.WEXITSTATUS(status) if os.WIFEXITED(status) else -os.WTERMSIG(status)
        sys.stderr.write('exit=%d\n' % code)
    sys.stdout.buffer.write(out)


if __name__ == '__main__':
    main()
