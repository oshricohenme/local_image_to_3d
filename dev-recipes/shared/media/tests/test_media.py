"""Network-free contract and process tests; these do not certify model inference."""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest

from lift_media.prepare import prepare
from lift_media.runner import context, digest, environment, expand, load, run

RECIPES = Path(__file__).resolve().parents[3]


class CatalogTests(unittest.TestCase):
    def test_every_recipe_has_pinned_installation_and_complete_argument_bindings(self):
        manifests = sorted(RECIPES.glob("*/files/media.json"))
        self.assertEqual(len(manifests), 54)
        for path in manifests:
            with self.subTest(recipe=path.parent.parent.name):
                recipe = json.loads((path.parent.parent / "recipe.yaml").read_text())
                spec = json.loads(path.read_text())
                self.assertEqual(recipe["schema"], 2)
                self.assertIn(digest(path), recipe["prepare"][0])
                self.assertEqual(set(spec["tasks"]), {t["id"] for t in recipe["tasks"]})
                if "repo" in recipe:
                    self.assertRegex(recipe["commit"], r"^[a-f0-9]{40}$")
                for asset in spec["assets"].values():
                    self.assertRegex(asset["revision"], r"^[a-f0-9]{40}$")
                    self.assertIn(asset, recipe["weights"])
                base = context(path.parent.parent) | {key: "/cache/" + key for key in spec["assets"]}
                for command in spec["prepare"]:
                    for argument in command:
                        expand(argument, base)
                for task in recipe["tasks"]:
                    args = base | {s["key"]: s["default"] for s in task["settings"]}
                    args |= {i["name"]: "input with spaces" for i in task["inputs"]}
                    args["out"] = "/job output"
                    impl = spec["tasks"][task["id"]]
                    args |= {key + "_file": "/job/" + file for key, file in impl.get("text_files", {}).items()}
                    for command in impl["commands"]:
                        self.assertIsInstance(command, list)
                        expanded = [expand(a, args) for a in command]
                        self.assertNotIn(Path(expanded[0]).name, ("pip", "uv", "git", "hf", "sh", "bash"))
                    self.assertTrue(impl["outputs"])
                    for pattern in impl["outputs"]:
                        self.assertFalse(Path(pattern).is_absolute())
                        self.assertNotIn("..", Path(pattern).parts)
                # Only Lift metadata and adapters belong in each recipe, never an upstream checkout.
                files = {str(f.relative_to(path.parent.parent)) for f in path.parent.parent.rglob("*")
                         if f.is_file() and "__pycache__" not in f.parts}
                self.assertEqual(files, {"launcher.py", "recipe.yaml", "files/media.json"})

    def test_generation_is_offline_and_interpolation_does_not_reinterpret_prompts(self):
        text = "a {model} with $(touch /tmp/should-not-exist); `id`\n日本語"
        self.assertEqual(expand("{prompt}", {"prompt": text}), text)
        env = environment({"env": {"MODEL_HOME": "{root}/models"}}, {"root": "/install"}, offline=True)
        self.assertEqual(env["MODEL_HOME"], "/install/models")
        self.assertEqual(env["HF_HUB_OFFLINE"], "1")
        self.assertEqual(env["TRANSFORMERS_OFFLINE"], "1")


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.recipe = self.root / "recipe"
        (self.recipe / "files").mkdir(parents=True)
        (self.root / "repo").mkdir()
        self.path = self.recipe / "files/media.json"
        self.receipt = self.root / "media-prepared.json"
        self.spec = {"assets": {}, "prepare": [], "required": [], "tasks": {}}

    def write(self):
        self.path.write_text(json.dumps(self.spec))
        return digest(self.path)

    def job(self, text="hello"):
        stages = []
        return SimpleNamespace(task="generate", out_dir=self.root / "out", inputs={"prompt": text},
                               settings={}, stage=lambda *a: stages.append(a)), stages

    def test_installer_fetches_gated_assets_first_and_publishes_receipt_after_preparation(self):
        assets = self.root / "cache"
        assets.mkdir()
        (assets / "weights").write_text("weights")
        self.spec.update(assets={"open": {"repo": "open", "revision": "a"},
                                 "gated": {"repo": "gated", "revision": "b", "gated": True, "files": ["weights"]}},
                         links={"{root}/linked": "{gated}/weights"}, required=["{root}/ready", "{root}/linked"],
                         prepare=[["{python}", "-c", "from pathlib import Path; import sys; Path(sys.argv[1]).write_text('ready')", "{root}/ready"]])
        calls = []
        def download(**kwargs):
            self.assertFalse(self.receipt.exists())
            calls.append(kwargs)
            return str(assets)
        prepare(self.recipe, self.write(), download=download)
        self.assertEqual([c["repo_id"] for c in calls], ["gated", "open"])
        self.assertEqual(calls[0]["allow_patterns"], ["weights"])
        self.assertTrue((self.root / "linked").is_symlink())
        _, values = load(SimpleNamespace(recipe_dir=self.recipe))
        self.assertEqual(values["gated"], str(assets))
        (self.root / "ready").unlink()
        with self.assertRaisesRegex(RuntimeError, "Installed model file is missing"):
            load(SimpleNamespace(recipe_dir=self.recipe))

    def test_failed_or_changed_preparation_cannot_leave_a_valid_receipt(self):
        prepare(self.recipe, self.write(), download=lambda **kw: "unused")
        self.spec["prepare"] = [["{python}", "-c", "raise RuntimeError('missing codec')"]]
        expected = self.write()
        with self.assertRaises(subprocess.CalledProcessError):
            prepare(self.recipe, expected, download=lambda **kw: "unused")
        self.assertFalse(self.receipt.exists())
        with self.assertRaisesRegex(RuntimeError, "installation pin"):
            prepare(self.recipe, "wrong hash", download=lambda **kw: "unused")
        self.spec["prepare"] = []
        self.spec["required"] = ["{root}/missing"]
        with self.assertRaisesRegex(RuntimeError, "did not produce"):
            prepare(self.recipe, self.write(), download=lambda **kw: "unused")
        self.assertFalse(self.receipt.exists())

    def test_missing_and_stale_receipts_refuse_loading(self):
        self.write()
        ctx = SimpleNamespace(recipe_dir=self.recipe)
        with self.assertRaisesRegex(RuntimeError, "preparation is missing"):
            load(ctx)
        self.receipt.write_text(json.dumps({"spec_sha256": "old", "assets": {}}))
        with self.assertRaisesRegex(RuntimeError, "setup changed"):
            load(ctx)

    def test_process_preserves_literal_inputs_streams_logs_and_returns_every_stem(self):
        program = ("from pathlib import Path; import os,sys; "
                   "assert os.environ['HF_HUB_OFFLINE'] == '1'; "
                   "Path(sys.argv[1]).write_text(sys.argv[2]); "
                   "Path(sys.argv[3]).write_bytes(b'wave'); print('[Stage] Synthesizing')")
        self.spec["tasks"]["generate"] = {"commands": [["{python}", "-c", program, "{out}/target.wav", "{prompt}", "{out}/residual.wav"]],
                                            "outputs": ["target.wav", "residual.wav"]}
        prompt = "$(touch nope) `id` ; {out}\nwhales 🐋"
        job, stages = self.job(prompt)
        job.settings = {"root": "untrusted", "python": "wrong", "out": "/wrong"}
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            outputs = run((self.spec, context(self.recipe)), job)
        self.assertEqual(len(outputs), 2)
        self.assertEqual(Path(outputs[0]).read_text(), prompt)
        self.assertIn("[Stage] Synthesizing", printed.getvalue())
        self.assertEqual(stages[-1], ("Complete", 1.0))
        self.assertFalse((self.root / "repo/nope").exists())

    def test_stale_empty_missing_or_escaping_outputs_are_failures(self):
        job, _ = self.job()
        job.out_dir.mkdir()
        target = job.out_dir / "result.wav"
        target.write_text("stale result")
        self.spec["tasks"]["generate"] = {"commands": [["{python}", "-c", "pass"]], "outputs": ["result.wav"]}
        with self.assertRaisesRegex(RuntimeError, "nonempty output"):
            run((self.spec, context(self.recipe)), job)
        target.unlink()
        target.symlink_to(self.path)
        self.write()
        with self.assertRaisesRegex(RuntimeError, "nonempty output"):
            run((self.spec, context(self.recipe)), job)
        target.unlink()
        self.spec["tasks"]["generate"]["commands"][0][2] = "from pathlib import Path; import sys; Path(sys.argv[1]).touch()"
        self.spec["tasks"]["generate"]["commands"][0].append("{out}/result.wav")
        with self.assertRaisesRegex(RuntimeError, "nonempty output"):
            run((self.spec, context(self.recipe)), job)

    def test_process_failure_propagates_without_success_stage(self):
        self.spec["tasks"]["generate"] = {"commands": [["{python}", "-c", "raise SystemExit(3)"]], "outputs": ["result.wav"]}
        job, stages = self.job()
        with self.assertRaises(subprocess.CalledProcessError):
            run((self.spec, context(self.recipe)), job)
        self.assertNotIn(("Complete", 1.0), stages)


if __name__ == "__main__":
    unittest.main()
