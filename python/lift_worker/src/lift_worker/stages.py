"""Progress stages parsed from upstream output with recipe-declared regexes."""
from __future__ import annotations

import functools
import re

# Every model's launcher may print "[Stage] <what it's doing>"; recipes don't need to declare it.
STAGE_LINE = {"pattern": r"^\[Stage\] (?P<name>.+)$"}


class StageParser:
    """Each pattern may use the named groups `name`, `pct` (0-100), or `n` and `total`.

    A match without `name` keeps the previous stage name (e.g. a bare tqdm bar).
    """

    def __init__(self, patterns: list[dict]):
        self._rx = [re.compile(p["pattern"]) for p in [STAGE_LINE, *patterns]]
        self._name = ""

    def named(self, name: str) -> None:
        """A stage the launcher reported: bars without a name of their own continue it."""
        self._name = name

    def feed(self, line: str) -> tuple[str, float | None] | None:
        for rx in self._rx:
            m = rx.search(line)
            if not m:
                continue
            g = m.groupdict()
            if g.get("name"):
                self._name = g["name"].strip()
            fraction = None
            if g.get("pct") is not None:
                fraction = float(g["pct"]) / 100
            elif g.get("n") is not None and g.get("total"):
                fraction = int(g["n"]) / int(g["total"])
            if fraction is not None:
                fraction = max(0.0, min(1.0, fraction))
            return self._name, fraction
        return None


def announce(owner, steps: dict[str, str]) -> None:
    """Wraps `owner`'s functions (a class's methods or a module's functions) so each prints "[Stage] <text>" as
    it starts: names the upstream steps that print nothing themselves, like decoding or baking. Upstream's own
    files stay unmodified; this changes only the running process. A name upstream no longer has is skipped:
    a missing label must never stop a model from loading."""
    for name, text in steps.items():
        original = getattr(owner, name, None)
        if original is None:
            continue

        @functools.wraps(original)
        def wrapper(*args, _original=original, _text=text, **kwargs):
            print(f"[Stage] {_text}", flush=True)
            return _original(*args, **kwargs)

        setattr(owner, name, wrapper)
