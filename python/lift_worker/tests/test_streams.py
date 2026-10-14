import threading

from lift_worker.streams import TaggedStream


def collect():
    lines = []
    return lines, (lambda job, line: lines.append((job, line)))


def test_splits_lines_and_carriage_returns():
    lines, sink = collect()
    s = TaggedStream(sink, lambda: "j1")
    s.write("a\nb\rc")
    assert lines == [("j1", "a"), ("j1", "b")]
    s.write("\r\n")
    assert lines[-1] == ("j1", "c")


def test_partial_line_waits_for_drain():
    lines, sink = collect()
    s = TaggedStream(sink, lambda: None)
    s.write("partial")
    assert lines == []
    s.drain()
    assert lines == [(None, "partial")]


def test_buffers_are_per_thread():
    lines, sink = collect()
    local = threading.local()
    s = TaggedStream(sink, lambda: getattr(local, "job", None))

    def work(job):
        local.job = job
        s.write(f"from {job} ")
        s.write("done\n")

    threads = [threading.Thread(target=work, args=(j,)) for j in ("a", "b")]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert sorted(lines) == [("a", "from a done"), ("b", "from b done")]
