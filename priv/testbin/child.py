#!/usr/bin/env python3
import signal
import sys
import time


def write_and_flush(data: str) -> None:
    sys.stdout.write(data)
    sys.stdout.flush()


def cmd_print_lines() -> int:
    write_and_flush("hello\nworld\n\n")
    return 0


def cmd_wait_stdin() -> int:
    sys.stdin.buffer.read()
    return 0


def cmd_partial_line() -> int:
    write_and_flush("HELLO")
    time.sleep(1.0)
    return 0


def cmd_long_line(length: int) -> int:
    write_and_flush("x" * length + "\n")
    return 0


def cmd_spam_bytes(total: int, chunk: int) -> int:
    remaining = total
    while remaining > 0:
        size = chunk if remaining > chunk else remaining
        write_and_flush("x" * size + "\n")
        remaining -= size
    return 0


def cmd_exit_code(code: int) -> int:
    return code


def cmd_ignore_sigterm() -> int:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    while True:
        time.sleep(1.0)


def main() -> int:
    if len(sys.argv) < 2:
        sys.stderr.write("usage: child.py <mode> [args]\n")
        return 2

    mode = sys.argv[1]
    if mode == "print_lines":
        return cmd_print_lines()
    if mode == "wait_stdin":
        return cmd_wait_stdin()
    if mode == "partial_line":
        return cmd_partial_line()
    if mode == "long_line":
        if len(sys.argv) < 3:
            sys.stderr.write("usage: child.py long_line <length>\n")
            return 2
        return cmd_long_line(int(sys.argv[2]))
    if mode == "spam_bytes":
        if len(sys.argv) < 4:
            sys.stderr.write("usage: child.py spam_bytes <total> <chunk>\n")
            return 2
        return cmd_spam_bytes(int(sys.argv[2]), int(sys.argv[3]))
    if mode == "exit_code":
        if len(sys.argv) < 3:
            sys.stderr.write("usage: child.py exit_code <code>\n")
            return 2
        return cmd_exit_code(int(sys.argv[2]))
    if mode == "ignore_sigterm":
        return cmd_ignore_sigterm()

    sys.stderr.write("unknown mode\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())
