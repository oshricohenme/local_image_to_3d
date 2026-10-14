"""fd separation and per-thread line tagging."""
from __future__ import annotations

import io
import json
import os
import re
import threading

_SPLIT = re.compile(r"\r\n|\r|\n")


def separate_fds() -> int:
    """Duplicate fd 1 for the protocol, then point fd 1 at stderr, so native prints can't corrupt it."""
    proto = os.dup(1)
    os.dup2(2, 1)
    return proto


class Channel:
    """Protocol writer: one JSON object per line on a private fd. Thread-safe."""

    def __init__(self, fd: int):
        self._f = os.fdopen(fd, "w", buffering=1, encoding="utf-8")
        self._lock = threading.Lock()

    def send(self, **msg) -> None:
        # ASCII only: U+2028, U+2029 and U+0085 are line breaks to Swift and would split a message.
        line = json.dumps(msg, ensure_ascii=True, default=str)
        with self._lock:
            self._f.write(line + "\n")
            self._f.flush()


class TaggedStream(io.TextIOBase):
    """Stands in for sys.stdout / sys.stderr.

    Text is buffered per thread; each complete line (split on \\n or \\r, so tqdm
    redraws count) goes to on_line(job_of(), line).
    """

    encoding = "utf-8"

    def __init__(self, on_line, job_of):
        super().__init__()
        self._on_line = on_line
        self._job_of = job_of
        self._local = threading.local()

    def writable(self) -> bool:
        return True

    def isatty(self) -> bool:
        return False

    def fileno(self) -> int:
        return 2  # code that writes to the raw fd lands on stderr, outside the protocol

    def write(self, s: str) -> int:
        *lines, rest = _SPLIT.split(getattr(self._local, "text", "") + s)
        self._local.text = rest
        for line in lines:
            if line:
                self._on_line(self._job_of(), line)
        return len(s)

    def drain(self) -> None:
        """Emit this thread's partial last line, if any."""
        rest = getattr(self._local, "text", "")
        self._local.text = ""
        if rest:
            self._on_line(self._job_of(), rest)

    def flush(self) -> None:
        pass  # partial lines stay buffered until a newline or drain()
