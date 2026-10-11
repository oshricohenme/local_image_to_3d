"""Entry: python -m lift_worker [--check] '<config json>'.

Config keys: launcher (path to launcher.py), repo_dir, recipe_dir, stages ([{pattern}]),
heartbeat_seconds, setting_types ({task: {key: type}}). One job at a time.
"""
from __future__ import annotations

import json
import sys

from .streams import Channel, TaggedStream, separate_fds
from .worker import Worker, load_launcher


def main(argv: list[str]) -> int:
    check = bool(argv) and argv[0] == "--check"
    cfg = json.loads(argv[-1])
    if check:
        load_launcher(cfg)
        print("lift_worker: launcher OK")
        return 0
    channel = Channel(separate_fds())
    worker = Worker(cfg, channel)
    out, err = TaggedStream(worker.on_line, worker.current_job), TaggedStream(worker.on_line, worker.current_job)
    worker.streams = [out, err]
    sys.stdout, sys.stderr = out, err
    worker.start()
    worker.serve(sys.stdin)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
