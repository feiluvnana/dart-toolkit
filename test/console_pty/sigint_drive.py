#!/usr/bin/env python3
"""Send SIGINT to a command under a pty; report its exit code.

Usage: sigint_drive.py OUT_FILE SIG_DELAY_SECS -- CMD...
Prints EXIT=<code> (exit code, or SIGNAL-<n>, or ALIVE on timeout).
"""
import os
import pty
import sys
import time
import select
import signal
import fcntl
import termios
import struct

out_file = sys.argv[1]
sig_delay = float(sys.argv[2])
assert sys.argv[3] == '--'
cmd = sys.argv[4:]

pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
flags = fcntl.fcntl(fd, fcntl.F_GETFL)
fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)

out = b''
start = time.time()
sent = False
code = 'ALIVE'
while time.time() - start < 25:
    el = time.time() - start
    if not sent and el > sig_delay:
        try:
            os.kill(pid, signal.SIGINT)
        except ProcessLookupError:
            break
        sent = True
    try:
        chunk = os.read(fd, 65536)
        if chunk:
            out += chunk
    except OSError:
        pass
    try:
        done, status = os.waitpid(pid, os.WNOHANG)
        if done == pid:
            if os.WIFEXITED(status):
                code = 'exit=%d' % os.WEXITSTATUS(status)
            elif os.WIFSIGNALED(status):
                code = 'SIGNAL-%d' % os.WTERMSIG(status)
            else:
                code = 'status=%d' % status
            break
    except ChildProcessError:
        code = 'REAPED'
        break
    time.sleep(0.2)
try:
    os.close(fd)
except OSError:
    pass
with open(out_file, 'wb') as f:
    f.write(out)
print('EXIT=' + code)
