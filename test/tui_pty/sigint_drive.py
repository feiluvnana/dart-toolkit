#!/usr/bin/env python3
"""Send SIGINT to a command under a pty; capture the terminal output.

Usage: sigint_drive.py OUT_FILE SIG_DELAY_SECS -- CMD...
Exits 0 after the child exits (or after a 25 s budget).
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

out = b''
start = time.time()
sent = False
while time.time() - start < 25:
    if not sent and time.time() - start > sig_delay:
        os.kill(pid, signal.SIGINT)
        sent = True
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    try:
        done, _ = os.waitpid(pid, os.WNOHANG)
        if done == pid and sent:
            break
    except ChildProcessError:
        break
flags = fcntl.fcntl(fd, fcntl.F_GETFL)
fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
try:
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        out += chunk
except OSError:
    pass
try:
    os.close(fd)
except OSError:
    pass
with open(out_file, 'wb') as f:
    f.write(out)
