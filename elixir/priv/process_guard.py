"""Linux: shell 終了後も子孫を回収し、終了確認を書き残してから終了する。"""

import ctypes
import os
import signal
import subprocess
import sys
import time


def children(pid):
    try:
        with open(f"/proc/{pid}/task/{pid}/children", encoding="ascii") as stream:
            direct = [int(value) for value in stream.read().split()]
    except FileNotFoundError:
        return []
    return [descendant for child in direct for descendant in children(child)] + direct


def reap():
    while True:
        try:
            if os.waitpid(-1, os.WNOHANG)[0] == 0:
                return
        except ChildProcessError:
            return


def belongs_to_guard(pid):
    while pid > 1:
        if pid == os.getpid():
            return True
        try:
            with open(f"/proc/{pid}/stat", encoding="ascii") as stream:
                pid = int(stream.read().rsplit(") ", 1)[1].split()[1])
        except FileNotFoundError:
            return False
    return False


def stop_children():
    deadline = time.monotonic() + 4
    while True:
        descendants = children(os.getpid())
        if not descendants:
            return
        for pid in descendants:
            try:
                descriptor = os.pidfd_open(pid)
                try:
                    if belongs_to_guard(pid):
                        signal.pidfd_send_signal(descriptor, signal.SIGKILL)
                finally:
                    os.close(descriptor)
            except ProcessLookupError:
                pass
        reap()
        if time.monotonic() >= deadline:
            raise RuntimeError("descendant termination not confirmed")
        time.sleep(0.01)


def main():
    # 親を失った子孫も引き取る。setsid / double fork でも追跡を失わない。
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
        raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER failed")
    stopping = False

    def stop(_signal, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print(f"__SYMPHONY_SESSION__ {os.getpid()}", flush=True)
    output = open(sys.argv[3], "wb") if sys.argv[3] else None
    child = subprocess.Popen(
        ["bash", "-lc", sys.argv[1]],
        stdout=output,
        stderr=subprocess.STDOUT if output else None,
    )
    status = 0
    try:
        while not stopping:
            try:
                status = child.wait(timeout=0.05)
                break
            except subprocess.TimeoutExpired:
                pass
    finally:
        stop_children()
        if output:
            output.close()
    # この記録がない限り、呼出側は workspace の排他を解除しない。
    with open(sys.argv[2], "x", encoding="ascii") as stream:
        stream.write("stopped\n")
    return status if status >= 0 else 128 - status


if __name__ == "__main__":
    sys.exit(main())
