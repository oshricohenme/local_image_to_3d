"""Executed only by the model installer, before Lift records Installed."""
import argparse
import json
from pathlib import Path

from .runner import context, digest, execute, expand


def prepare(recipe_dir, expected, download=None):
    path = Path(recipe_dir) / "files/media.json"
    if digest(path) != expected:
        raise RuntimeError("Recipe setup manifest does not match its installation pin.")
    if download is None:
        from huggingface_hub import snapshot_download
        download = snapshot_download
    spec = json.loads(path.read_text())
    values = context(recipe_dir)
    receipt = Path(values["root"]) / "media-prepared.json"
    receipt.unlink(missing_ok=True)
    assets = {}
    # Gated repositories fail before downloading other large components.
    ordered = sorted(spec.get("assets", {}).items(), key=lambda item: not item[1].get("gated", False))
    for key, asset in ordered:
        print(f"[Stage] Downloading {asset['repo']}", flush=True)
        assets[key] = download(repo_id=asset["repo"], revision=asset["revision"],
                               allow_patterns=asset.get("files"))
    values.update(assets)
    for folder in spec.get("directories", []):
        Path(expand(folder, values)).mkdir(parents=True, exist_ok=True)
    for target, source in spec.get("links", {}).items():
        link = Path(expand(target, values))
        resolved = Path(expand(source, values))
        if not resolved.exists():
            raise RuntimeError(f"Missing downloaded component: {resolved}")
        link.parent.mkdir(parents=True, exist_ok=True)
        if link.is_symlink():
            link.unlink()
        if not link.exists():
            link.symlink_to(resolved, target_is_directory=resolved.is_dir())
    execute(spec.get("prepare", []), values, spec)
    for required in spec.get("required", []):
        if not Path(expand(required, values)).exists():
            raise RuntimeError(f"Model setup did not produce {required}")
    temporary = receipt.with_suffix(".tmp")
    temporary.write_text(json.dumps({"spec_sha256": expected, "assets": assets}, indent=2))
    temporary.replace(receipt)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("recipe_dir")
    parser.add_argument("--expected", required=True)
    args = parser.parse_args()
    prepare(args.recipe_dir, args.expected)
