import json
import os
import subprocess
import sys
import time

from conftest import FIXTURE, SRC

TAG = {"pattern": r"^\[Stage\] (?P<name>.+)$"}
TQDM = {"pattern": r"^(?P<name>[^:|]+):\s*(?P<pct>\d+)%\|"}


def is_ev(name, job=None):
    return lambda e: e["ev"] == name and (job is None or e.get("job") == job)


def test_ready_and_native_output_kept_off_protocol(worker):
    w = worker()
    ready = w.until(is_ev("ready"))[-1]
    assert ready["protocol"] == 1 and ready["load_seconds"] >= 0
    w.run("j1")
    w.until(is_ev("done", "j1"))
    assert all(json.loads(line) for line in w.raw_stdout)  # every protocol line is JSON
    time.sleep(0.2)
    assert "native noise at load" in w.stderr and "loading model" in w.stderr


def test_run_logs_tagged_and_done(worker):
    w = worker()
    w.until(is_ev("ready"))
    w.run("j1")
    evs = w.until(is_ev("done", "j1"))
    logs = [e["line"] for e in evs if e["ev"] == "log"]
    assert "start j1" in logs
    assert "no newline at end" in logs  # partial last line drained before done
    done = evs[-1]
    assert done["outputs"] == [os.path.abspath(w.tmp / "j1" / "out.txt")]
    assert (w.tmp / "j1" / "out.txt").read_text() == "j1"


def test_thread_started_by_upstream_tagged_to_only_job(worker):
    w = worker()
    w.until(is_ev("ready"))
    w.run("j1", thread_log=True)
    evs = w.until(is_ev("done", "j1"))
    assert {"ev": "log", "job": "j1", "line": "from upstream thread"} in evs


def test_stages_parsed_from_output(worker):
    w = worker(stages=[TAG, TQDM])
    w.until(is_ev("ready"))
    w.run("j1", stages=True)
    stages = [(e["name"], e["fraction"]) for e in w.until(is_ev("done", "j1")) if e["ev"] == "stage"]
    assert stages == [("Sampling", None), ("Sampling", 0.5), ("Sampling", 1.0)]


def test_system_exit_fails_job_not_worker(worker):
    w = worker()
    w.until(is_ev("ready"))
    w.run("j1", exit=True)
    err = w.until(is_ev("error", "j1"))[-1]
    assert err["message"].startswith("SystemExit") and "Traceback" in err["traceback"]
    w.run("j2")
    w.until(is_ev("done", "j2"))


def test_exception_reported(worker):
    w = worker()
    w.until(is_ev("ready"))
    w.run("j1", **{"raise": True})
    assert w.until(is_ev("error", "j1"))[-1]["message"] == "ValueError: boom"


def test_heartbeat(worker):
    w = worker(heartbeat_seconds=0.1)
    hb = w.until(is_ev("heartbeat"))[-1]
    assert isinstance(hb["mps_allocated"], int)


def test_shutdown_op_exits(worker):
    w = worker()
    w.until(is_ev("ready"))
    w.send(op="shutdown")
    assert w.p.wait(5) == 0


def test_stdin_eof_exits_even_while_busy(worker):
    w = worker()
    w.until(is_ev("ready"))
    w.run("j1", sleep=30)
    w.until(lambda e: e.get("line") == "start j1")
    w.p.stdin.close()  # the app died: the worker must not outlive it
    assert w.p.wait(5) == 0


def test_load_failure_reports_and_exits(worker):
    w = worker(env={"FIXTURE_LOAD_FAIL": "1"})
    err = w.until(is_ev("error"))[-1]
    assert err["job"] is None and "load failed on purpose" in err["message"]
    assert w.p.wait(5) == 1


def test_check_mode(tmp_path):
    cfg = json.dumps({"launcher": str(FIXTURE), "stages": [TAG]})
    r = subprocess.run([sys.executable, "-m", "lift_worker", "--check", cfg], capture_output=True, text=True,
                       env={**os.environ, "PYTHONPATH": str(SRC)})
    assert r.returncode == 0, r.stderr
    bad = json.dumps({"launcher": str(FIXTURE), "stages": [{"pattern": "("}]})
    r = subprocess.run([sys.executable, "-m", "lift_worker", "--check", bad], capture_output=True, text=True,
                       env={**os.environ, "PYTHONPATH": str(SRC)})
    assert r.returncode != 0


def test_float_settings_arrive_as_float(worker):
    w = worker(setting_types={"t": {"scale": "float"}})
    w.until(is_ev("ready"))
    w.run("j1", scale=2)  # JSON 2 for a float setting
    assert {"ev": "log", "job": "j1", "line": "scale is float"} in w.until(is_ev("done", "j1"))


def test_unicode_line_separators_stay_inside_one_protocol_line(worker):
    w = worker()
    w.until(is_ev("ready"))
    w.run("j1", separators=True)
    evs = w.until(is_ev("done", "j1"))
    assert {"ev": "log", "job": "j1", "line": "a\u2028b\u2029c\u0085d"} in evs
    # Swift's line splitting treats U+2028/U+2029/U+0085 as line breaks: they must be escaped on the wire.
    assert not any(ch in line for line in w.raw_stdout for ch in "\u2028\u2029\u0085")


def test_launcher_imports_from_recipe_files(tmp_path):
    """A recipe may carry its own code in files/; the launcher imports it like any module."""
    (tmp_path / "files").mkdir()
    (tmp_path / "files" / "cube_helper.py").write_text("def answer():\n    return 42\n")
    (tmp_path / "launcher.py").write_text("from cube_helper import answer\n\ndef run(state, job):\n    return []\n")
    cfg = json.dumps({"launcher": str(tmp_path / "launcher.py"), "recipe_dir": str(tmp_path)})
    r = subprocess.run([sys.executable, "-m", "lift_worker", "--check", cfg], capture_output=True, text=True,
                       env={**os.environ, "PYTHONPATH": str(SRC)})
    assert r.returncode == 0, r.stderr


def test_free_memory_returns_the_mps_cache(monkeypatch):
    # After every job the worker hands PyTorch's cached Metal memory back, so an idle model holds only its weights.
    sys.path.insert(0, str(SRC))
    from types import SimpleNamespace
    from lift_worker import worker as w
    emptied = []
    fake = SimpleNamespace(backends=SimpleNamespace(mps=SimpleNamespace(is_available=lambda: True)),
                           mps=SimpleNamespace(empty_cache=lambda: emptied.append(1)))
    monkeypatch.setitem(sys.modules, "torch", fake)
    w._free_memory()
    assert emptied == [1]
    monkeypatch.delitem(sys.modules, "torch")
    w._free_memory()  # no torch imported: nothing to free, and it never imports torch itself
    assert "torch" not in sys.modules


def test_a_quiet_job_logs_that_it_is_still_working(worker):
    # A model that prints nothing for a while (TRELLIS.2 decoding, a long bake) must never look frozen.
    w = worker(heartbeat_seconds=0.1, quiet_seconds=0.3)
    w.until(is_ev("ready"))
    w.run("j1", sleep=1.0)
    evs = w.until(is_ev("done", "j1"))
    notes = [e["line"] for e in evs if e["ev"] == "log" and e["line"].startswith("[Lift] Still working")]
    assert notes and "no new output for" in notes[0] and "CPU" in notes[0]
    assert 2 <= len(notes) <= 4  # one per quiet period, not one per heartbeat
    assert notes[0] != notes[-1]  # each counts from the last real output, so the later one says longer


def test_output_resets_the_quiet_clock(worker):
    w = worker(heartbeat_seconds=0.1, quiet_seconds=5)
    w.until(is_ev("ready"))
    w.run("j1", sleep=0.5)
    evs = w.until(is_ev("done", "j1"))
    assert not [e for e in evs if e["ev"] == "log" and e["line"].startswith("[Lift] Still working")]


def test_a_stage_line_names_the_step_for_every_model(worker):
    # No recipe pattern needed: "[Stage] …" is built in, and a stage without a bar has no fraction.
    w = worker()  # stages: []
    w.until(is_ev("ready"))
    w.run("j1", stages=True)
    evs = w.until(is_ev("done", "j1"))
    assert {"ev": "stage", "job": "j1", "name": "Sampling", "fraction": None} in evs


def test_a_reported_stage_is_logged_too(worker):
    w = worker()
    w.until(is_ev("ready"))
    w.run("j1", report=True)
    evs = w.until(is_ev("done", "j1"))
    assert {"ev": "stage", "job": "j1", "name": "Writing the file", "fraction": 0.5} in evs
    assert "[Stage] Writing the file" in [e["line"] for e in evs if e["ev"] == "log"]


def test_announce_names_an_upstream_step_when_it_starts(capsys):
    sys.path.insert(0, str(SRC))
    from lift_worker.stages import announce

    class Pipeline:
        def decode(self, x):
            return x * 2

    announce(Pipeline, {"decode": "Decoding the 3D shape"})
    assert Pipeline().decode(3) == 6
    assert capsys.readouterr().out == "[Stage] Decoding the 3D shape\n"
    assert Pipeline.decode.__name__ == "decode"
