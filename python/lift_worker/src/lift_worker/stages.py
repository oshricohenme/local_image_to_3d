"""Progress stages parsed from upstream output with recipe-declared regexes."""
from __future__ import annotations

import re


class StageParser:
    """Each pattern may use the named groups `name`, `pct` (0-100), or `n` and `total`.

    A match without `name` keeps the previous stage name (e.g. a bare tqdm bar).
    """

    def __init__(self, patterns: list[dict]):
        self._rx = [re.compile(p["pattern"]) for p in patterns]
        self._name = ""

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
