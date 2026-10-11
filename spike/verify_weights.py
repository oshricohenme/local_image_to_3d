"""THROWAWAY: verify HF weights are fully downloaded and intact (prototype of Lift's models_verify_weights).

Usage: uv run --with huggingface_hub python spike/verify_weights.py REPO[@REVISION] [REPO ...]
For each repo: fetch the file list (LFS sha256 + sizes, git blob ids) from the HF API, check every
file exists in the local cache, check its size, and hash it (sha256 for LFS, git blob sha1 otherwise).
Exit code 0 only if every file of every repo verifies.
"""
import hashlib
import json
import os
import sys

from huggingface_hub import HfApi, hf_hub_download
from huggingface_hub.errors import LocalEntryNotFoundError


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 24), b""):
            h.update(chunk)
    return h.hexdigest()


def git_blob_sha1(path, size):
    h = hashlib.sha1(f"blob {size}\0".encode())
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def verify(spec):
    repo, _, revision = spec.partition("@")
    info = HfApi().model_info(repo, revision=revision or None, files_metadata=True)
    problems, total = [], 0
    for s in info.siblings:
        try:
            path = hf_hub_download(repo, s.rfilename, revision=info.sha, local_files_only=True)
        except LocalEntryNotFoundError:
            problems.append({"file": s.rfilename, "problem": "missing"})
            continue
        size = os.path.getsize(path)
        expected = s.lfs.size if s.lfs else s.size
        total += size
        if expected is not None and size != expected:
            problems.append({"file": s.rfilename, "problem": f"size {size} != {expected}"})
        elif s.lfs and sha256(path) != s.lfs.sha256:
            problems.append({"file": s.rfilename, "problem": "sha256 mismatch"})
        elif not s.lfs and s.blob_id and git_blob_sha1(path, size) != s.blob_id:
            problems.append({"file": s.rfilename, "problem": "blob sha1 mismatch"})
    return {"repo": repo, "revision": info.sha, "files": len(info.siblings),
            "gb": round(total / 1e9, 2), "ok": not problems, "problems": problems}


results = [verify(a) for a in sys.argv[1:]]
print(json.dumps(results, indent=2))
sys.exit(0 if all(r["ok"] for r in results) else 1)
