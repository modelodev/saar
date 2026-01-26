#!/usr/bin/env python3
"""Fixture that fails immediately for managed-port tests."""
from __future__ import annotations

import sys


def main() -> None:
    sys.stderr.write("missing_server fixture invoked\n")
    sys.exit(1)


if __name__ == "__main__":
    main()
