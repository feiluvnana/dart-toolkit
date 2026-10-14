#!/usr/bin/env python3
"""Ctrl-Z under a real pty with a minimal job-control shell: the app must stop
itself with the terminal restored, then take the terminal back on SIGCONT.

Usage: suspend_drive.py -- CMD...
Prints isig_off= stopped= left= isig_back= reentered= isig_off_again= exit=."""
import fcntl, os, pty, select, signal, struct, sys, termios, time


def shell(cmd):
    """Session leader of the pty: runs cmd as a foreground job, like a shell."""
    signal.signal(signal.SIGTTOU, signal.SIG_IGN)
    job = os.fork()
    if job == 0:
        os.setpgid(0, 0)
        os.tcsetpgrp(0, os.getpid())
        os.execvp(cmd[0], cmd)
    os.setpgid(job, job)
    _, st = os.waitpid(job, os.WUNTRACED)
    if os.WIFSTOPPED(st):
        os.tcsetpgrp(0, os.getpgrp())
        sys.stdout.write('\nSTOPPED\n')
        sys.stdout.flush()
        time.sleep(1.0)
        os.tcsetpgrp(0, job)
        os.killpg(job, signal.SIGCONT)
        _, st = os.waitpid(job, 0)
    code = os.WEXITSTATUS(st) if os.WIFEXITED(st) else -os.WTERMSIG(st)
    sys.stdout.write('\nEXIT=%d\n' % code)
    sys.stdout.flush()
    os._exit(0)


def read_until(fd, mark, secs):
    out = b''
    end = time.time() + secs
    while time.time() < end and mark not in out:
        if select.select([fd], [], [], 0.1)[0]:
            try:
                out += os.read(fd, 65536)
            except OSError:
                break
    return out


def main():
    cmd = sys.argv[sys.argv.index('--') + 1:]
    pid, fd = pty.fork()
    if pid == 0:
        shell(cmd)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
    read_until(fd, b'\x1b[?2004h', 30)
    isig_off = not termios.tcgetattr(fd)[3] & termios.ISIG
    os.write(fd, b'\x1a')
    out = read_until(fd, b'STOPPED', 5)
    stopped = b'STOPPED' in out
    isig_back = bool(termios.tcgetattr(fd)[3] & termios.ISIG)
    again = read_until(fd, b'\x1b[?1049h', 5)
    time.sleep(0.3)
    isig_off_again = not termios.tcgetattr(fd)[3] & termios.ISIG
    os.write(fd, b'\x1b')
    rest = read_until(fd, b'EXIT=', 10)
    code = rest.split(b'EXIT=')[-1].split()[0].decode() if b'EXIT=' in rest else None
    print('isig_off=%s stopped=%s left=%s isig_back=%s reentered=%s isig_off_again=%s exit=%s' % (
        isig_off, stopped, b'\x1b[?1049l' in out, isig_back, b'\x1b[?1049h' in again, isig_off_again, code))


main()
