#!/usr/bin/env python3
"""Run a command under a real pty, feeding input bytes at delays.

Usage: drive.py --size ROWS COLS [--feed DELAY_SECS PY_ESCAPED_BYTES]... -- CMD...
Captured terminal output goes to stdout."""
import os
import pty
import sys
import time
import select
import fcntl
import termios
import struct

def main():
    argv = sys.argv[1:]
    rows, cols = 24, 80
    inputs = []  # (delay_secs, bytes)
    i = 0
    while i < len(argv):
        if argv[i] == '--size':
            rows, cols = int(argv[i + 1]), int(argv[i + 2])
            i += 3
        elif argv[i] == '--feed':
            inputs.append((float(argv[i + 1]), argv[i + 2].encode('utf-8', 'surrogateescape').decode('unicode_escape').encode('latin1')))
            i += 3
        elif argv[i] == '--':
            i += 1
            break
        else:
            i += 1
    cmd = argv[i:]

    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(cmd[0], cmd)
    # Set window size on the pty.
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
    out = b''
    start = time.time()
    pending = list(inputs)
    exited = False
    # Total budget: 25s.
    try:
        while time.time() - start < 25:
            now = time.time() - start
            while pending and pending[0][0] <= now:
                _, data = pending.pop(0)
                try:
                    os.write(fd, data)
                except OSError:
                    pass
            timeout = 0.1
            if pending:
                timeout = min(0.5, max(0.05, pending[0][0] - now))
            r, _, _ = select.select([fd], [], [], timeout)
            if r:
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                out += chunk
            # Check child exit (non-blocking).
            done, _ = os.waitpid(pid, os.WNOHANG)
            if done == pid:
                exited = True
            if done == pid and not pending:
                # Drain briefly, then stop.
                time.sleep(0.3)
                while True:
                    r, _, _ = select.select([fd], [], [], 0.1)
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
        while not exited and time.time() < deadline:
            try:
                exited = os.waitpid(pid, os.WNOHANG)[0] == pid
            except ChildProcessError:
                exited = True
            if not exited:
                time.sleep(0.05)
        if not exited:
            # The pty closing below sends SIGHUP, which would hide a hang.
            sys.stderr.write('child did not exit on its own\n')
        try:
            os.close(fd)
        except OSError:
            pass
        if not exited:
            try:
                os.waitpid(pid, 0)
            except (OSError, ChildProcessError):
                pass
    sys.stdout.buffer.write(out)

if __name__ == '__main__':
    main()
