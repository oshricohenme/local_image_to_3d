"""The worker: loads the recipe launcher once, runs jobs on a thread pool, reports over the channel."""
from __future__ import annotations

import gc
import importlib.util
import json
import os
import sys
import threading
import time
import traceback
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace

from . import PROTOCOL
from .stages import StageParser


def load_launcher(cfg: dict):
    """Import the recipe's launcher.py and check its stage patterns compile."""
    StageParser(cfg.get("stages", []))
    # The recipe's own code (files/) and the upstream repo are importable; files/ first.
    for path in (cfg.get("repo_dir"), os.path.join(cfg["recipe_dir"], "files") if cfg.get("recipe_dir") else None):
        if path and path not in sys.path:
            sys.path.insert(0, path)
    spec = importlib.util.spec_from_file_location("lift_launcher", cfg["launcher"])
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if not callable(getattr(module, "run", None)):
        raise TypeError(f"{cfg['launcher']} must define run(state, job)")
    return module


def _mps_allocated() -> int:
    torch = sys.modules.get("torch")  # never import torch here: it is the launcher's choice
    try:
        if torch is not None and torch.backends.mps.is_available():
            return int(torch.mps.driver_allocated_memory())
    except Exception:  # noqa: BLE001 - a heartbeat must never fail
        pass
    return 0


def _free_memory() -> None:
    """After a job: drop its garbage and hand PyTorch's cached Metal memory back to macOS, so an idle
    model holds only what it keeps loaded (the cache otherwise stays at the job's peak)."""
    gc.collect()
    torch = sys.modules.get("torch")  # never import torch here: it is the launcher's choice
    try:
        if torch is not None and torch.backends.mps.is_available():
            torch.mps.empty_cache()
    except Exception:  # noqa: BLE001 - freeing memory must never fail a job
        pass


def _duration(seconds: float) -> str:
    return f"{seconds:.0f} s" if seconds < 90 else f"{seconds / 60:.0f} min"


def coerce_settings(settings: dict, types: dict) -> dict:
    """JSON can't tell 1 from 1.0: make `float` settings floats again (bools stay bools)."""
    out = dict(settings)
    for key, typ in types.items():
        v = out.get(key)
        if typ == "float" and isinstance(v, int) and not isinstance(v, bool):
            out[key] = float(v)
    return out


class Job:
    """What launcher.run(state, job) receives."""

    def __init__(self, msg: dict, patterns: list[dict], types: dict | None = None):
        self.id: str = msg["job"]
        self.step: int = msg.get("step", 0)
        self.task: str = msg["task"]
        self.inputs: dict = msg.get("inputs", {})
        self.settings: dict = coerce_settings(msg.get("settings", {}), (types or {}).get(self.task, {}))
        self.out_dir: str = msg["out_dir"]
        self.parser = StageParser(patterns)
        self._channel = None
        # Since the job's last output line: when that was, and the process's CPU time then (Worker._note_quiet).
        self.last_output = self.quiet_since = time.monotonic()
        self.cpu_mark = time.process_time()

    def stage(self, name: str, fraction: float | None = None) -> None:
        """Launchers may report a stage directly; it goes into the job's log too."""
        self.parser.named(name)
        self._channel.send(ev="log", job=self.id, line=f"[Stage] {name}")
        self._channel.send(ev="stage", job=self.id, name=name, fraction=fraction)


class Worker:
    def __init__(self, cfg: dict, channel):
        self.cfg = cfg
        self.ch = channel
        # One job per worker process (spec §8): the app cancels a job by killing the process. The job runs
        # on its own thread so the main thread keeps reading stdin (shutdown, EOF).
        self.pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="lift-job")
        self.jobs: dict[str, Job] = {}
        self.lock = threading.Lock()
        self.local = threading.local()
        self.streams: list = []
        self.launcher = None
        self.state = None

    # --- log routing -------------------------------------------------------
    def current_job(self) -> str | None:
        job = getattr(self.local, "job", None)
        if job:
            return job
        with self.lock:  # a line from a thread upstream started: the only running job owns it
            return next(iter(self.jobs)) if len(self.jobs) == 1 else None

    def on_line(self, job_id: str | None, line: str) -> None:
        job = self.jobs.get(job_id) if job_id else None
        if job is None:
            os.write(2, (line + "\n").encode("utf-8", "replace"))
            return
        job.last_output = job.quiet_since = time.monotonic()
        job.cpu_mark = time.process_time()
        self.ch.send(ev="log", job=job_id, line=line)
        parsed = job.parser.feed(line)
        if parsed:
            self.ch.send(ev="stage", job=job_id, name=parsed[0], fraction=parsed[1])

    # --- lifecycle ---------------------------------------------------------
    def start(self) -> None:
        threading.Thread(target=self._heartbeat, daemon=True, name="lift-heartbeat").start()
        t0 = time.perf_counter()
        try:
            self.launcher = load_launcher(self.cfg)
            ctx = SimpleNamespace(repo_dir=self.cfg.get("repo_dir"), recipe_dir=self.cfg.get("recipe_dir"))
            load = getattr(self.launcher, "load", None)
            self.state = load(ctx) if callable(load) else None
        except BaseException as e:  # noqa: BLE001 - includes SystemExit from upstream
            for s in self.streams:
                s.drain()
            self.ch.send(ev="error", job=None, message=f"{type(e).__name__}: {e}", traceback=traceback.format_exc())
            os._exit(1)
        for s in self.streams:
            s.drain()
        self.ch.send(ev="ready", protocol=PROTOCOL, load_seconds=round(time.perf_counter() - t0, 3))

    def _heartbeat(self) -> None:
        every = float(self.cfg.get("heartbeat_seconds", 2.0))
        while True:
            time.sleep(every)
            self.ch.send(ev="heartbeat", mps_allocated=_mps_allocated())
            self._note_quiet()

    def _note_quiet(self) -> None:
        """A job that has printed nothing for `quiet_seconds` gets a log line saying so, with how hard the
        process is working, once per quiet period: a silent model (decoding, baking) never looks frozen."""
        quiet = float(self.cfg.get("quiet_seconds", 30))
        now = time.monotonic()
        with self.lock:
            jobs = list(self.jobs.values())
        for job in jobs:
            window = now - job.quiet_since
            if window < quiet:
                continue
            cpu = time.process_time()
            busy = (cpu - job.cpu_mark) / window * 100
            job.quiet_since, job.cpu_mark = now, cpu
            self.ch.send(ev="log", job=job.id, line=f"[Lift] Still working: no new output for {_duration(now - job.last_output)} (CPU {busy:.0f}%)")

    def serve(self, stdin) -> None:
        """Read ops until shutdown or EOF (EOF means the app went away), then exit at once."""
        for raw in stdin:
            raw = raw.strip()
            if not raw:
                continue
            msg = json.loads(raw)
            op = msg.get("op")
            if op == "run":
                job = Job(msg, self.cfg.get("stages", []), self.cfg.get("setting_types"))
                job._channel = self.ch
                with self.lock:
                    self.jobs[job.id] = job
                self.pool.submit(self._run, job)
            elif op == "shutdown":
                break
        os._exit(0)

    def _run(self, job: Job) -> None:
        self.local.job = job.id
        try:
            os.makedirs(job.out_dir, exist_ok=True)
            outputs = self.launcher.run(self.state, job) or []
            result = dict(ev="done", job=job.id, outputs=[os.path.abspath(o) for o in outputs])
        except BaseException as e:  # noqa: BLE001 - SystemExit from upstream fails the job, not the worker
            # Strings only: the exception's frames hold the job's tensors, which must go before memory is freed.
            result = dict(ev="error", job=job.id, message=f"{type(e).__name__}: {e}", traceback=traceback.format_exc())
        for s in self.streams:
            s.drain()
        self.local.job = None
        with self.lock:
            self.jobs.pop(job.id, None)
        # Before reporting: Lift sends the next job as soon as it hears this one ended, and measures the model's
        # memory then to decide whether to unload it, so the job's memory must already be back.
        _free_memory()
        self.ch.send(**result)
