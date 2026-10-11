import json
import os
import queue
import subprocess
import sys
import threading
import time
from pathlib import Path

import pytest

SRC = Path(__file__).resolve().parents[1] / "src"
FIXTURE = Path(__file__).resolve().parent / "fixtures" / "launcher.py"


class WorkerProc:
    """Drives `python -m lift_worker` over real pipes, like the app does."""

    def __init__(self, tmp_path, env=None, **cfg):
        config = {"launcher": str(FIXTURE), "repo_dir": str(tmp_path), "recipe_dir": str(tmp_path),
                  "stages": [], "heartbeat_seconds": 60, **cfg}
        self.tmp = tmp_path
        self.p = subprocess.Popen(
            [sys.executable, "-m", "lift_worker", json.dumps(config)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env={**os.environ, "PYTHONPATH": str(SRC), **(env or {})},
        )
        self.events: queue.Queue = queue.Queue()
        self.raw_stdout: list[str] = []
        self.stderr: list[str] = []
        threading.Thread(target=self._pump_out, daemon=True).start()
        threading.Thread(target=self._pump_err, daemon=True).start()

    def _pump_out(self):
        for line in self.p.stdout:
            self.raw_stdout.append(line)
            self.events.put(json.loads(line))  # a non-JSON line fails the test thread loudly

    def _pump_err(self):
        for line in self.p.stderr:
            self.stderr.append(line.rstrip("\n"))

    def send(self, **op):
        self.p.stdin.write(json.dumps(op) + "\n")
        self.p.stdin.flush()

    def run(self, job, **settings):
        self.send(op="run", job=job, step=0, task="t", inputs={}, settings=settings,
                  out_dir=str(self.tmp / job))

    def until(self, pred, timeout=10.0):
        """Collect events until pred(event) is true; return all collected."""
        got, end = [], time.monotonic() + timeout
        while time.monotonic() < end:
            try:
                ev = self.events.get(timeout=0.1)
            except queue.Empty:
                continue
            got.append(ev)
            if pred(ev):
                return got
        raise AssertionError(f"timed out; got {got}; stderr {self.stderr}")

    def close(self):
        if self.p.poll() is None:
            self.p.kill()
        self.p.wait(5)


@pytest.fixture
def worker(tmp_path):
    procs = []

    def make(**kw):
        w = WorkerProc(tmp_path, **kw)
        procs.append(w)
        return w

    yield make
    for w in procs:
        w.close()
