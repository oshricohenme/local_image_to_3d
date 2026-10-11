from lift_worker.stages import StageParser

TAG = {"pattern": r"^\[Stage\] (?P<name>.+)$"}
TQDM = {"pattern": r"^(?P<name>[^:|]+):\s*(?P<pct>\d+)%\|"}
COUNT = {"pattern": r"step (?P<n>\d+)/(?P<total>\d+)"}


def test_stage_tag_without_fraction():
    assert StageParser([TAG]).feed("[Stage] Loading model") == ("Loading model", None)


def test_tqdm_percent():
    assert StageParser([TQDM]).feed("Sampling:  45%|####5     | 9/20 [00:03<00:04]") == ("Sampling", 0.45)


def test_count_keeps_previous_name():
    p = StageParser([TAG, COUNT])
    p.feed("[Stage] Decoding")
    assert p.feed("step 3/4") == ("Decoding", 0.75)


def test_no_match():
    assert StageParser([TAG, TQDM]).feed("just a log line") is None


def test_fraction_clamped():
    assert StageParser([TQDM]).feed("X: 140%|") == ("X", 1.0)
