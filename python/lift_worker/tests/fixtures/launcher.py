"""Test launcher: behaviour is driven by job settings."""
import os
import sys
import threading
import time


def load(ctx):
    print("loading model")             # untagged: goes to stderr
    os.write(1, b"native noise at load\n")  # fd 1 now points at stderr
    if os.environ.get("FIXTURE_LOAD_FAIL"):
        raise RuntimeError("load failed on purpose")
    return {"repo_dir": ctx.repo_dir}


def run(state, job):
    s = job.settings
    print(f"start {job.id}")
    if s.get("separators"):
        print("a\u2028b\u2029c\u0085d")  # Unicode line separators inside one line
    if "scale" in s:
        print(f"scale is {type(s['scale']).__name__}")
    os.write(1, b"native noise in job\n")
    if s.get("stages"):
        print("[Stage] Sampling")
        sys.stderr.write("Sampling:  50%|#####     | 1/2\r")
        sys.stderr.write("Sampling: 100%|##########| 2/2\n")
    if s.get("report"):
        job.stage("Writing the file", 0.5)
    if s.get("thread_log"):
        t = threading.Thread(target=lambda: print("from upstream thread"))
        t.start()
        t.join()
    time.sleep(float(s.get("sleep", 0)))
    if s.get("exit"):
        sys.exit(3)
    if s.get("raise"):
        raise ValueError("boom")
    if s.get("crash"):
        os._exit(7)
    print("no newline at end", end="")
    path = os.path.join(job.out_dir, "out.txt")
    with open(path, "w") as f:
        f.write(job.id)
    return [path]
