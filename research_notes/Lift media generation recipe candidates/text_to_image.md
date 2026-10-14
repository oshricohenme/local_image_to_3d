# Open-weight text-to-image models as Lift recipes (Mac-runnable only, as of 2026-10-11)

Scope: per the user's scope change, this catalog lists only models with evidence of a working Apple Silicon path: upstream PyTorch/MPS, a community Mac port, an MLX port (mflux), or stable-diffusion.cpp (sd.cpp) with Metal. Draw Things support is recorded as extra evidence that a model runs on Apple Silicon. It is not a Lift path, because Lift cannot drive the app. Models with no Mac path found are listed in one line at the end.

Method notes. Licenses, gating, parameter counts, creation dates and likes come from the live Hugging Face API (`/api/models/<id>`, queried 2026-10-11). The "HF repo storage" figure is the whole repo, including alternate files and history, so it overstates a single download. Pipeline names were listed live from diffusers `main` (latest release v0.41.0, 2026-10-06). The mflux CLI names come from its per-model READMEs at `main` (latest release v.0.22.0, 2026-10-08). Arena ranks were read from the live Artificial Analysis text-to-image leaderboard.

---

## Q1. Repo, CLI, and diffusers status: which models have a clean CLI Lift can call?

### Takeaway
Few upstream repos ship a CLI Lift can run unattended on a Mac. Z-Image's `inference.py` hard-codes the prompt. FLUX.2's `scripts/cli.py` is interactive and hard-codes CUDA. Qwen-Image offers only diffusers snippets and a Gradio demo. The cleanest CLI covering the most models is **mflux** (MIT, MLX-native), with one typed `mflux-generate-*` command per model, edit commands included. The other route is a small diffusers launcher script, since every model shortlisted below has an official diffusers pipeline.

### Cited Findings
- mflux is a "line-by-line MLX port" of diffusers/transformers models, installed with `uv tool install --upgrade mflux`. Its example command is `mflux-generate-z-image-turbo --prompt ... --width 1280 --height 500 --seed 42 --steps 9 -q 8`. It moved to the `mflux-community` org in Aug 2026. MIT license, ~2.5k stars, last push 2026-10-10, latest release v.0.22.0 (2026-10-08). — [mflux README](https://github.com/mflux-community/mflux); [releases](https://github.com/mflux-community/mflux/releases)
- mflux's model table covers Z-Image (6B), Krea 2 (12B), FLUX.2 klein (4B and 9B), Ideogram 4 (9B), ERNIE-Image (8B), Lens (3.8B plus a 20B text encoder), Ming-Image (6.15B plus a 16B MoE text encoder), Boogu Image (10B), FIBO (8B), Qwen Image (20B), Qwen Image 2.1 (7.1B plus an 8B text encoder), FLUX.1 (12B), plus SeedVR2 upscaling and Depth Pro. — [mflux README](https://github.com/mflux-community/mflux)
- mflux commands per model, from the model READMEs:
  - FLUX.2: `mflux-generate-flux2`, `mflux-generate-flux2-edit`
  - Z-Image: `mflux-generate-z-image`, `mflux-generate-z-image-turbo`, `mflux-generate-z-image-controlnet`
  - Qwen: `mflux-generate-qwen`, `mflux-generate-qwen-edit`
  - Qwen 2.1: `mflux-generate-qwen-2.1`, `mflux-generate-qwen-2.1-edit`
  - Krea 2: `mflux-generate-krea2`
  - ERNIE: `mflux-generate-ernie-image`, `mflux-generate-ernie-image-turbo`
  - Lens: `mflux-generate-lens`
  - Ming: `mflux-generate-ming`
  - Boogu: `mflux-generate-boogu`
  - FLUX.1: `mflux-generate`, `-fill`, `-kontext`, `-redux`, `-depth`, `-controlnet`, `-in-context(-edit)`
  - Sources: [flux2](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/flux2/README.md), [z_image](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/z_image/README.md), [qwen](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/qwen/README.md), [qwen21](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/qwen21/README.md), [krea2](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/krea2/README.md), [ernie_image](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/ernie_image/README.md), [flux](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/flux/README.md)
- mflux logs go to stderr, so piping stdout is unaffected. `--stepwise-image-output-dir` saves intermediate images. `--low-ram` and `--mlx-cache-limit-gb` cap memory. `--make-conf` writes a JSON metadata sidecar. — [mflux common README](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/common/README.md)
- **Z-Image upstream** (`Tongyi-MAI/Z-Image`, Apache-2.0, 12.1k stars, last push 2026-02-09):
  - It has `inference.py` and `batch_inference.py`. `inference.py` is 76 lines with no argparse: the prompt is hard-coded.
  - It auto-selects the device in the order cuda → tpu → **mps** → cpu.
  - The attention backend defaults to `ZIMAGE_ATTENTION=_native_flash`.
  - Dependencies are only torch>=2.5, transformers, safetensors, loguru, pillow, accelerate and huggingface_hub.
  - Sources: [inference.py](https://github.com/Tongyi-MAI/Z-Image/blob/main/inference.py); [pyproject](https://github.com/Tongyi-MAI/Z-Image/blob/main/pyproject.toml); [repo](https://github.com/Tongyi-MAI/Z-Image)
- **FLUX.2 upstream** (`black-forest-labs/flux2`, Apache-2.0 code, 2.7k stars, last push 2026-03-12):
  - `scripts/cli.py` (653 lines) uses `fire` but runs an interactive session with `input()` prompts.
  - It hard-codes `torch.device("cuda")` and `torch.Generator(device="cuda")`.
  - It pins torch==2.8.0, transformers==4.56.1 and openai==2.8.1, and is "tested on GB200 with CUDA 12.9".
  - Sources: [cli.py](https://github.com/black-forest-labs/flux2/blob/main/scripts/cli.py); [pyproject](https://github.com/black-forest-labs/flux2/blob/main/pyproject.toml); [repo](https://github.com/black-forest-labs/flux2)
- **Qwen-Image upstream** (8.4k stars, last push 2026-02-10) offers diffusers snippets and `src/examples/demo.py` (Gradio). It has no standalone CLI, and its sample code selects only CUDA or CPU. — [QwenLM/Qwen-Image](https://github.com/QwenLM/Qwen-Image)
- diffusers `main` has pipelines for: flux, flux2 (`pipeline_flux2`, `_klein`, `_klein_inpaint`, `_klein_kv`), qwenimage, qwenimage21, z_image, stable_diffusion_3, stable_diffusion_xl, chroma, hidream_image, krea2, ernie_image, ideogram4, glm_image, longcat_image, bria_fibo, pixart_alpha, sana, lumina2, cogview4, kolors, omnigen, ovis_image and more. It has **no** Boogu pipeline. — [diffusers pipelines dir](https://github.com/huggingface/diffusers/tree/main/src/diffusers/pipelines)
- stable-diffusion.cpp (MIT, 7.6k stars, last push 2026-10-10) supports a Metal backend on macOS. Its image models include SD1/2/XL, SD3/3.5, FLUX.1, FLUX.2-dev/klein, Lens, Chroma, Qwen Image, Qwen Image 2.1, LongCat Image, Z-Image, Ovis-Image, ERNIE-Image, Boogu, Krea2, HiDream-O1-Image, Ideogram4, Ming-Image Design and PixArt. Its edit models are FLUX.1-Kontext-dev, the Qwen Image Edit series, LongCat Image Edit and Boogu Image Edit. It reads GGUF and safetensors. — [stable-diffusion.cpp README](https://github.com/leejet/stable-diffusion.cpp)

### Inferences
- For Lift's "pin one repo, run its CLI" model, pinning `mflux-community/mflux` at a tag and exposing each `mflux-generate-*` entry point as a recipe gives a clean CLI with typed flags (`--prompt --width --height --seed --steps -q --image-path --image-strength --image-paths`). It needs no CUDA shim and no launcher. One catch: mflux uses MLX, not PyTorch, so Lift's PyTorch install step would be dead weight for these recipes.
- Pinning the upstream repos themselves needs a small launcher for every shortlisted model:
  - Z-Image: about 20 lines wrapping `inference.py`, or diffusers `ZImagePipeline`.
  - FLUX.2 klein: diffusers `Flux2KleinPipeline`, since the official CLI is interactive and CUDA-only.
  - Qwen-Image, ERNIE and Krea 2: diffusers pipelines.
- sd.cpp has the widest Mac coverage, edit models included. It is a C++ binary rather than a Python repo, so it doesn't fit the uv/venv recipe shape unless Lift wraps it.

### Gaps
- I didn't verify the exact stdout/stderr progress format of mflux (whether it prints tqdm bars and what they look like). Lift's progress parser needs this, so check by running a command once.
- I didn't verify whether a Python binding for sd.cpp exists and is maintained.

---

## Q2. Licenses (code vs. weights), commercial use, and gating

### Takeaway
The commercially clean Mac-runnable models are Z-Image (Turbo and base), FLUX.2 [klein] 4B, Qwen-Image / 2512 / Edit-2511, ERNIE-Image, Chroma1-HD, Boogu, LongCat-Image, FLUX.1 [schnell] (all Apache-2.0), and Ming-Image and HiDream (MIT). Several of the highest-ranked open models are non-commercial or capped:
- Qwen-Image-2.1 (Qwen Research license)
- Ideogram 4 (non-commercial, gated)
- FLUX.2 [dev] and [klein] 9B (FLUX Non-Commercial)
- FLUX.1 [dev], Kontext and Krea-dev (FLUX.1-dev non-commercial)
- Krea 2 (community license capped at $1M revenue and 50 seats)
- SD3.5 (Stability Community license, free under $1M)

### Cited Findings
- HF API, queried 2026-10-11 (license / gated):
  - **Apache-2.0, not gated:** FLUX.2-klein-4B (3.88B); Qwen-Image, Qwen-Image-2512 and Qwen-Image-Edit-2511 (20.43B); Z-Image-Turbo and Z-Image (6.15B); ERNIE-Image and ERNIE-Image-Turbo (8.03B); Chroma1-HD (8.9B); Boogu-Image-0.1-Turbo (10.29B); LongCat-Image and LongCat-Image-Edit.
  - **Apache-2.0, gated "auto" (click-through):** FLUX.1-schnell.
  - **MIT, not gated:** Ming-Image-0.1-Design (6.15B), HiDream-O1-Image (8.8B), HiDream-I1-Full and HiDream-E1-1 (17.11B).
  - **Non-commercial or custom, gated "auto":** FLUX.1-dev, FLUX.1-Kontext-dev, FLUX.1-Krea-dev and FLUX.1-Fill-dev (`flux-1-dev-non-commercial-license`); FLUX.2-dev (32.22B) and FLUX.2-klein-9B (9.08B) (`flux-non-commercial-license`); SD3.5 Large, Medium and Large-Turbo (`stabilityai-ai-community`); Krea-2-Turbo and Krea-2-Raw (12.82B, `krea-2-community-license`); ideogram-4-fp8 (9.28B) and -nf4 (`ideogram-4-non-commercial`); briaai/FIBO (8.29B, `bria-fibo`).
  - **Custom, not gated:** Qwen-Image-2.1 (7.12B, `qwen-research`).
  - **openrail++, not gated:** SDXL base 1.0 (2.57B) and PixArt-Sigma (0.61B).
  - Sources: [FLUX.2-klein-4B](https://huggingface.co/black-forest-labs/FLUX.2-klein-4B), [FLUX.2-klein-9B](https://huggingface.co/black-forest-labs/FLUX.2-klein-9B), [FLUX.2-dev](https://huggingface.co/black-forest-labs/FLUX.2-dev), [FLUX.1-dev](https://huggingface.co/black-forest-labs/FLUX.1-dev), [FLUX.1-schnell](https://huggingface.co/black-forest-labs/FLUX.1-schnell), [Qwen-Image-2512](https://huggingface.co/Qwen/Qwen-Image-2512), [Qwen-Image-Edit-2511](https://huggingface.co/Qwen/Qwen-Image-Edit-2511), [Qwen-Image-2.1](https://huggingface.co/Qwen/Qwen-Image-2.1), [Z-Image-Turbo](https://huggingface.co/Tongyi-MAI/Z-Image-Turbo), [ERNIE-Image](https://huggingface.co/baidu/ERNIE-Image), [Krea-2-Turbo](https://huggingface.co/krea/Krea-2-Turbo), [Ming-Image](https://huggingface.co/inclusionAI/Ming-Image-0.1-Design), [HiDream-O1](https://huggingface.co/HiDream-ai/HiDream-O1-Image), [Chroma1-HD](https://huggingface.co/lodestones/Chroma1-HD), [Boogu](https://huggingface.co/Boogu/Boogu-Image-0.1-Turbo), [SD3.5 Large](https://huggingface.co/stabilityai/stable-diffusion-3.5-large), [ideogram-4-fp8](https://huggingface.co/ideogram-ai/ideogram-4-fp8), [FIBO](https://huggingface.co/briaai/FIBO)
- Code repo licenses: mflux MIT; Z-Image Apache-2.0; flux2 Apache-2.0; ERNIE-Image Apache-2.0; krea-ai/krea-2 Apache-2.0 (code only, weights are under the community license); HiDream-O1 MIT; sd.cpp MIT. — GitHub API: [mflux](https://github.com/mflux-community/mflux), [Z-Image](https://github.com/Tongyi-MAI/Z-Image), [flux2](https://github.com/black-forest-labs/flux2), [ERNIE-Image](https://github.com/baidu/ERNIE-Image), [krea-2](https://github.com/krea-ai/krea-2), [HiDream-O1](https://github.com/HiDream-ai/HiDream-O1-Image)
- FLUX.2 klein 9B and dev: outputs can be used commercially, but deploying the model commercially needs a paid BFL license. klein-4B is "the only unrestricted FLUX.2 checkpoint". — [invideo license matrix, Aug 2026](https://invideo.io/blog/open-source-image-models-licenses/)
- Qwen-Image-2.1 was released 2026-09-20 under the Qwen Research License, which bars commercial use without a separate license obtained by email. One report says that email route bounces. The original Qwen-Image line was Apache 2.0. — [Latenode](https://latenode.com/ai-trends/qwen-image-2-1-commercial-licence); [DataNorth](https://datanorth.ai/news/qwen-releases-qwen-image-2-1)
- Qwen-Image 2.0 / 2.0 Pro (Feb 2026) are closed and API-only, with no weights. — [invideo license matrix](https://invideo.io/blog/open-source-image-models-licenses/); consistent with [Qwen-Image repo news](https://github.com/QwenLM/Qwen-Image). **Contradicted by** [Thunder Compute](https://www.thundercompute.com/blog/best-open-source-image-generation-models), which lists "Qwen-Image 2.0, 7B, Apache 2.0". The HF API shows no Qwen-Image-2.0 weights repo, so Thunder Compute appears wrong.
- Krea 2 Community License: free commercial use under $1M annual revenue and 50 seats, with deployers required to implement content filtering. — [LocalAIMaster](https://localaimaster.com/blog/krea-2-local-guide). **Contradicted by** [ComfyUI Wiki](https://comfyui-wiki.com/en/news/2026-06-22-krea-2-open-source-text-to-image), which says non-commercial and research only. The HF model card is gated, so I couldn't read the license text directly.
- Ideogram 4 (released 2026-06-03, 9.3B): inference code is Apache-2.0, weights are under the Ideogram Non-Commercial Model Agreement, and the HF repo is gated. Self-hosted output can't be used commercially. — [invideo Ideogram 4](https://invideo.io/blog/ideogram-ai-image-generator/); [invideo license matrix](https://invideo.io/blog/open-source-image-models-licenses/)
- Lens (Microsoft): the Comfy-Org mirror card says `microsoft/Lens (mit)`, but `microsoft/Lens` returned HTTP 401 on 2026-10-11. It may be gated, renamed or withdrawn. — [Comfy-Org/Lens](https://huggingface.co/Comfy-Org/Lens)

### Inferences
- For a consumer app whose users may sell outputs, the low-risk defaults are Z-Image, FLUX.2 klein 4B, Qwen-Image-2512/Edit-2511 and ERNIE-Image. Non-commercial models (Qwen-Image-2.1, Ideogram 4, FLUX.2 dev / klein 9B, FLUX.1 dev) need an in-app license notice. Gated ones (FLUX.1/2 non-commercial, Krea 2, Ideogram 4, SD3.5, FIBO) need Lift's HF-token gated-repo flow.

### Gaps
- I couldn't read the Krea 2 license text first-hand because the repo is gated.
- I didn't fetch the Bria FIBO license terms.
- The current status of `microsoft/Lens` is unclear.

---

## Q3. Parameters, download size, and realistic memory on a Mac

### Takeaway
On a 16 GB Mac, the realistic options are FLUX.2 klein 4B and Z-Image Turbo, both quantized (4-bit or 6/8-bit), and ERNIE q4 (~6.2 GB on disk). The 24–36 GB tier adds Krea 2 q8, Ming q5 and Boogu. Qwen-Image (20B) and Qwen-Image-2.1 need 48–64 GB or more, because mflux keeps their large text encoders in bf16 unquantized. FLUX.2 [dev] (32B) is 64 GB+ territory via sd.cpp GGUF.

### Cited Findings
- **Z-Image:** weights are "large (~31GB)" unquantized, with a pre-quantized `filipstrand/Z-Image-Turbo-mflux-4bit` available. — [mflux z_image README](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/z_image/README.md)
  - Turbo "fits comfortably within 16G VRAM consumer devices", with 9 steps (8 DiT forwards) and guidance 0. — [HF card](https://huggingface.co/Tongyi-MAI/Z-Image-Turbo)
  - Draw Things' 6-bit Z-Image Turbo uses about 4 GiB of RAM. — [Draw Things blog](https://releases.drawthings.ai/p/quantify-z-image-turbo-efficiency)
- **FLUX.2 klein 4B:** 3.88B params, 4 steps, guidance 1.0, ~13 GB VRAM in bf16. — [HF card](https://huggingface.co/black-forest-labs/FLUX.2-klein-4B)
  - The upstream README says klein 4B fits in about 8 GB VRAM. — [flux2 repo](https://github.com/black-forest-labs/flux2)
  - A Q4 GGUF is about 2.6 GB. — [LocalAIMaster](https://localaimaster.com/blog/krea-2-local-guide)
- **Qwen-Image (mflux):** "requires downloading Qwen/Qwen-Image-2512 (~58GB full)". The text encoder takes about 14 GB (15.5 GB for edits), and `--quantize` doesn't shrink it, because mflux keeps the ~7B text encoder in bf16 on purpose. — [mflux qwen README](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/qwen/README.md)
- **Qwen-Image-2.1 (mflux):** ~33 GB bf16 on disk (14.2 GB transformer, 17.5 GB Qwen3-VL text encoder, 1.4 GB VAE). Peak memory is about 46 GB, so a 64 GB machine is the target. — [mflux qwen21 README](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/qwen21/README.md)
- **Krea 2 Turbo (mflux):** ~24 GB `turbo.safetensors` plus text encoder and VAE, ~33 GB total on first run. mflux recommends `-q 8`. — [mflux krea2 README](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/krea2/README.md)
  - The 12.9B model ships as Raw (~52 steps) and Turbo (8 steps). FP8 weights are about 13 GB and BF16 about 26 GB. It uses a Qwen3VL-4B text encoder and the Qwen-Image VAE. — [LocalAIMaster](https://localaimaster.com/blog/krea-2-local-guide)
- **ERNIE-Image (mflux):** ~22 GB unquantized, `-q 8` ~12 GB, `-q 4` ~6.2 GB. — [mflux ernie_image README](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/ernie_image/README.md)
  - It ships as Turbo (8-step) and SFT (50-step) variants. — [ComfyUI Wiki](https://comfyui-wiki.com/en/models/ernie)
- **Ming-Image (mflux):** 8-bit DiT plus a 4-bit MoE text encoder is about 17 GB on disk. Total footprint by quantization: q8 25.2 GB, q6 21.2 GB, q5 19.3 GB ("recommended for 24 GB Macs"), q4 17.3 GB. — [mflux ming_image README](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/ming_image/README.md)
  - Upstream's validated deployment is one GPU with at least 80 GiB. — [DataNorth](https://datanorth.ai/news/ant-group-releases-ming-image-0-1-design)
- **Ideogram 4:** fp8 and nf4 checkpoints, with nf4 fitting a 24 GB GPU. — [invideo](https://invideo.io/blog/ideogram-ai-image-generator/)
- **FLUX.2 [dev]:** 32B. Needs 24 GB with GGUF Q4, ~32 GB with FP8. — [Thunder Compute](https://www.thundercompute.com/blog/best-open-source-image-generation-models)
  - The HF repo totals 177.6 GB. — [HF](https://huggingface.co/black-forest-labs/FLUX.2-dev)
- **Lens:** 3.8B DiT plus a GPT-OSS 20B text encoder (mflux uses `mlx-community/gpt-oss-20b-MXFP4-Q8`). — [mflux README](https://github.com/mflux-community/mflux); [mflux lens README](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/lens/README.md)
- HF repo storage totals (upper bounds, not single downloads): klein-4B 23.7 GB; Z-Image-Turbo 54.0 GB; ERNIE-Image 39.3 GB; Krea-2-Turbo 62.5 GB; Ming 71.5 GB; Boogu 59.1 GB; Chroma1-HD 98.7 GB; SD3.5 Large 75.5 GB; SDXL 77.4 GB; HiDream-O1 35.2 GB; LongCat-Image 29.3 GB. — HF API (model pages linked in Q2)

### Inferences
- Lift's model picker should gate by RAM:
  - 16 GB: Z-Image Turbo q4/q6 and klein 4B q4.
  - 24–32 GB: adds ERNIE q8, Krea 2 q8, Ming q5 and klein 9B.
  - 48–64 GB+: Qwen-Image(-Edit) and Qwen-Image-2.1.
  - 64–128 GB: FLUX.2 dev GGUF via sd.cpp.

### Gaps
- I have no first-party per-file download totals for the diffusers bf16 layouts. The HF storage numbers include extra files.

---

## Q4. Apple Silicon status: MPS, MLX ports, sd.cpp, and measured speed

### Takeaway
Every shortlisted model has an MLX path through mflux, and most also have sd.cpp Metal and Draw Things support. The measured 1024² numbers:
- FLUX.2 klein 4B q4: ~6.8 s/step on an M1 Max, so ~30 s with 4 steps.
- Z-Image Turbo q4: ~10.7 s/step on an M1 Max, so ~1.5 min with 9 steps.
- Qwen-Image-2.1: ~78 s for 40 steps on an M5 Max.
- Ming: 4–4.5 min on a base M4 mini.

Upstream PyTorch on MPS works but is fragile on M1–M3: bf16 has no hardware support there, and forcing fp16 has produced black images.

### Cited Findings
- mflux measurements on an M1 Max (64 GB) at 1024², s/step without → with `--compute-precision float16`:
  - FLUX.2 klein 4B `-q 4`: 6.8 → 5.0
  - Z-Image Turbo `-q 4`: 10.7 → 7.5
  - FLUX.2 klein 9B unquantized: 11.6 → 10.5
  - Qwen-Image-2.1 edit with a 6-step LoRA: 12.6 → 10.8
  - The float16 gain is 18–22% on an M2 Ultra, 4–6% per step on an M4 Max, and zero on an M5 Max.
  - Source: [mflux common README](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/common/README.md)
- Qwen-Image-2.1 on mflux, M5 Max: ~1.5 s/step at 1024², ~78 s for a full 40-step generation, versus the "diffusers MPS reference at ~85 s". — [mflux qwen21 README](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/qwen21/README.md). This is also first-party evidence that the upstream diffusers pipeline runs on MPS.
- Ming-Image on a base M4 Mac mini (10-core GPU, 24 GB), q8 DiT with q5 text encoder, 12 steps: 1024² takes 4–4.5 min at 14.5 GB peak (~20 s/step); 512² takes 63 s. — [mflux ming_image README](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/ming_image/README.md)
- FLUX.2 klein 4B on an M1 Max with mflux or iris.c: 1024px in 30–40 s. — [lilting.ch](https://lilting.ch/en/articles/flux2-klein-4b-mflux-iris-m1-max). An estimate table on the same site lists "M4 Max 85 seconds" for 1024², but it doesn't say which model or framework, so it's unreliable. — [lilting.ch klein 9B](https://lilting.ch/en/articles/flux2-klein-apple-silicon)
- On M1/M2/M3, BF16 runs through software emulation (native BF16 starts with M4) and is about 2x slower than FP16. A Qwen Image Edit run went from ~80 s to ~10 min after a ComfyUI update switched weights to bf16. Forcing FP16 produced completely black output, which the author attributes to an MPS fp16 attention bug. — [lilting.ch](https://lilting.ch/en/articles/comfyui-qwen-mps-bf16-slowdown)
- Draw Things dates added (evidence the model runs on Apple Silicon):
  - SD3.5 Large / Large Turbo: Oct 2024
  - HiDream I1: Apr 2025
  - HiDream E1: May 2025
  - Chroma: May 2025
  - FLUX.1 Kontext: Jun 2025
  - Qwen Image: Aug 2025
  - Qwen Image Edit 2509: Oct 2025
  - Z-Image Turbo: Dec 2025
  - FLUX.2 dev: Dec 2025
  - Qwen Edit 2511 / Layered: Dec 2025
  - Qwen 2512: Jan 2026
  - FLUX.2 klein: Jan 2026
  - Z-Image base: Feb 2026
  - ERNIE Image: Apr 2026
  - Ideogram 4: Jul 2026
  - Krea 2: Jul 2026
  - Qwen Image 2.1: Sep 2026
  - Source: [Draw Things release notes](https://drawthings.ai/downloads/)
- Draw Things claims its Z-Image Turbo is up to 54% faster than other implementations on Apple devices. — [Draw Things blog](https://releases.drawthings.ai/p/quantify-z-image-turbo-efficiency)
- One M3 user reported 600 s/iteration for Z-Image Turbo in stable-diffusion.cpp versus 19 s/iteration in ComfyUI, so backend choice matters a lot. — [sd.cpp issue #1030](https://github.com/leejet/stable-diffusion.cpp/issues/1030)
- Z-Image upstream `inference.py` selects MPS automatically. Its default attention backend is `_native_flash`, and the repo recommends `_flash_3` for best speed. — [inference.py](https://github.com/Tongyi-MAI/Z-Image/blob/main/inference.py)
- The FLUX.2 upstream CLI hard-codes CUDA, so it won't run on MPS without patching. — [cli.py](https://github.com/black-forest-labs/flux2/blob/main/scripts/cli.py)

### Inferences
- The MLX route (mflux) is both faster and more robust than PyTorch MPS for these models, judging from the Qwen-2.1 comparison (78 s vs 85 s) and the bf16/fp16 pitfalls on M1–M3. That makes it the better default for Lift's non-developer users.
- If Lift runs upstream on MPS, the launcher should force SDPA attention, which avoids `_native_flash`. It should also pick fp16 versus bf16 by chip generation and verify that the output isn't black.

### Gaps
- I found no M4/M5 1024² timings for Z-Image Turbo or klein 4B, and none for 16 GB base M1/M2 machines. Lift should benchmark these itself.
- I didn't confirm that Z-Image's `_native_flash` backend falls back cleanly on MPS.

---

## Q5. CUDA-only dependencies in requirements

### Takeaway
The shortlisted upstream repos are mostly free of hard CUDA-only dependencies. Z-Image needs only torch/transformers/accelerate. FLUX.2 pins torch 2.8.0 with a cu129 index but has no flash_attn, though its code hard-codes CUDA. Optional flash-attn appears in several secondary repos.

### Cited Findings
- Z-Image depends on torch>=2.5.0, transformers>=4.51.0, safetensors, loguru, pillow, accelerate and huggingface_hub. Flash Attention 2/3 is optional via diffusers. — [Z-Image pyproject](https://github.com/Tongyi-MAI/Z-Image/blob/main/pyproject.toml); [repo](https://github.com/Tongyi-MAI/Z-Image)
- FLUX.2 depends on torch==2.8.0, torchvision==0.23.0, einops, transformers==4.56.1, safetensors, fire, openai==2.8.1 and accelerate, installed with the cu129 PyTorch index. — [flux2 pyproject](https://github.com/black-forest-labs/flux2/blob/main/pyproject.toml); [repo](https://github.com/black-forest-labs/flux2)
- HiDream-O1's README "highly recommend[s]" flash-attn, with a fallback when it isn't installed. — [HiDream-O1 repo](https://github.com/HiDream-ai/HiDream-O1-Image)
- mflux needs no CUDA. It is MLX plus HF tokenizers, and also has a DGX/NVIDIA install path. — [mflux README](https://github.com/mflux-community/mflux)

### Inferences
- Lift's existing shim (flash_attn/xformers/triton stand-ins) covers HiDream-O1. Upstream FLUX.2 needs source patching rather than a shim, because CUDA is hard-coded, which is another reason to use diffusers or mflux for klein.

### Gaps
- I didn't read requirements for ERNIE-Image, krea-ai/krea-2, Ming-Image or LongCat upstream repos. Their READMEs contain no flash-attn or Mac mentions.

---

## Q6. Quality reputation and project activity

### Takeaway
On the live Artificial Analysis arena, the top open-weights models are Qwen-Image-2.1 (rank 20, Elo 1036), Ideogram 4.0 (1012), FLUX.2 [dev] (1000) and Ming-Image-0.1-Design (999), all non-commercial or heavy. Among commercially clean and light models, FLUX.2 klein 9B and Z-Image Turbo tie (941), with ERNIE Turbo (924) close behind. Original Qwen-Image (889) and klein 4B (863) still beat FLUX.1 [dev] (841) and SD3.5 Large (840).

### Cited Findings
- Artificial Analysis text-to-image arena, open-weights rows (rank / Elo):
  - Qwen-Image-2.1: 20 / 1036
  - Ideogram 4.0 (Quality): 39 / 1012
  - Ideogram 4.0: 43 / 1004
  - FLUX.2 [dev]: 44 / 1000
  - Ming-Image-0.1-Design: 46 / 999
  - FLUX.2 [dev] Turbo: 49 / 997
  - HunyuanImage 3.0 Instruct: 50 / 996
  - Cosmos3-Super-Text2Image: 58 / 987
  - HiDream-O1-Image: 67 / 982
  - FLUX.2 [klein] 9B: 83 / 941
  - Z-Image Turbo: 84 / 941
  - ERNIE Image Turbo: 88 / 924
  - ERNIE Image: 96 / 913
  - GLM-Image: 107 / 891
  - Qwen Image: 108 / 889
  - HunyuanImage 2.1: 109 / 887
  - FIBO: 114 / 881
  - HiDream-I1-Dev: 120 / 874
  - FLUX.2 [klein] 4B: 126 / 863
  - LongCat Image: 128 / 861
  - FLUX.1 Krea [dev]: 130 / 847
  - FLUX.1 [dev]: 132 / 841
  - SD3.5 Large: 133 / 840
  - FLUX.1 [schnell]: 143 / 803
  - Lumina Image v2: 148 / 782
  - Playground v2.5: 150 / 777
  - SD3.5 Medium: 153 / 760
  - Sana Sprint 1.6B: 154 / 754
  - OmniGen V2: 156 / 727
  - Bagel: 162 / 706
  - SDXL 1.0: 164 / 678
  - Janus Pro: 167 / 533
  - Source: [Artificial Analysis leaderboard](https://artificialanalysis.ai/text-to-image/arena/leaderboard-text)
- Krea 2, Boogu and Lens didn't appear in the open-weights rows I extracted. — [same](https://artificialanalysis.ai/text-to-image/arena/leaderboard-text)
- ERNIE-Image's reported scores: GenEval 0.8856 and LongTextBench 0.9733 (secondary write-up). — [ComfyUI Wiki](https://comfyui-wiki.com/en/models/ernie); [LetsDataScience](https://letsdatascience.com/news/ernie-image-delivers-accurate-text-inclusive-image-generatio-d45de927)
- Ming-Image-0.1-Design targets text-heavy design (UI, infographics, posters) and outputs native RGBA. It is reported #1 among open models on a UI/UX design leaderboard (vendor-cited, unverified). — [DataNorth](https://datanorth.ai/news/ant-group-releases-ming-image-0-1-design); [ComfyUI Wiki](https://comfyui-wiki.com/en/models/ming-image)
- Z-Image-Turbo ranked #8 overall and #1 open-source on Artificial Analysis as of 2025-12-08. It has since been passed. — [Z-Image repo news](https://github.com/Tongyi-MAI/Z-Image)
- Qwen-Image is known for English and Chinese typography. — [Thunder Compute](https://www.thundercompute.com/blog/best-open-source-image-generation-models)
- Activity, from GitHub API last push and stars, and HF likes:
  - mflux: 2026-10-10, 2.5k stars
  - sd.cpp: 2026-10-10, 7.6k stars
  - Z-Image: 2026-02-09, 12.1k stars; Z-Image-Turbo 5,440 likes
  - flux2: 2026-03-12, 2.7k stars; klein-4B 1,018 likes, klein-9B 1,656 likes
  - Qwen-Image: 2026-02-10, 8.4k stars; Qwen-Image-2.1 3,224 likes
  - krea-2: 2026-07-24, 906 stars; Krea-2-Turbo 1,592 likes
  - ERNIE-Image: 2026-04-17, 511 stars; 678 likes
  - HiDream-O1: 2026-06-22, 1.45k stars
  - Sources: GitHub/HF pages linked above

### Inferences
- Superseded or stale: SDXL, Playground v2.5, PixArt-Sigma and SD3.5 Medium rank well below 2025–26 models. Janus-Pro's repo hasn't been pushed since 2025-02-01. FLUX.1 [dev]/[schnell] are labelled "legacy" by mflux, though FLUX.1 Kontext/Fill still matter for editing.

### Gaps
- I didn't capture text-rendering benchmark numbers (LongText/CVTG) for Z-Image or klein.

---

## Q7. Editing support (for Lift's editing UI)

### Takeaway
The strongest editing candidates on a Mac:
- **FLUX.2 klein**: one model for text-to-image, single or multi-reference instruction editing, img2img and inpainting.
- **Qwen-Image-Edit-2511**: instruction editing with multiple images, Apache.
- **Qwen-Image-2.1**: unified generation and editing, multi-reference, RGBA, but non-commercial.
- **FLUX.1 Kontext / Fill**: instruction editing and mask inpaint/outpaint, non-commercial.

Z-Image, Krea 2 and ERNIE offer only img2img strength in mflux. Z-Image's instruction-edit model is still unreleased.

### Cited Findings
- **FLUX.2 klein (4B/9B):**
  - All FLUX.2 models support text-to-image, single-reference editing and multi-reference editing. Upstream's interactive CLI exposes editing, but it is CUDA-only. — [flux2 repo](https://github.com/black-forest-labs/flux2)
  - diffusers has `Flux2KleinPipeline`, `Flux2KleinInpaintPipeline` (mask) and `Flux2KleinKV`. — [diffusers flux2](https://github.com/huggingface/diffusers/tree/main/src/diffusers/pipelines/flux2)
  - mflux `mflux-generate-flux2` supports img2img; `mflux-generate-flux2-edit --image-paths person.jpg glasses.jpg --prompt ...` handles multi-image editing; 9B-KV adds KV-cache editing. mflux says base (non-distilled) klein is worse for editing. — [mflux flux2 README](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/flux2/README.md)
- **Qwen-Image family:**
  - diffusers pipelines: `qwenimage_img2img`, `_inpaint`, `_controlnet`, `_controlnet_inpaint`, `_edit`, `_edit_inpaint`, `_edit_plus` (multi-image) and `_layered`. — [diffusers qwenimage](https://github.com/huggingface/diffusers/tree/main/src/diffusers/pipelines/qwenimage)
  - Edit (single image, 2025-08) was followed by Edit-2509 (multi-image) and Edit-2511 (better consistency, construction lines, novel viewpoints, built-in LoRA effects). Editing is instruction-based. — [Qwen-Image repo](https://github.com/QwenLM/Qwen-Image)
  - mflux: `mflux-generate-qwen-edit --image-paths dog1.png dog2.png`, with default guidance 2.5 for edits and 3.5 for text-to-image. — [mflux qwen README](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/qwen/README.md)
  - sd.cpp supports the Qwen Image Edit series. — [sd.cpp](https://github.com/leejet/stable-diffusion.cpp)
- **Qwen-Image-2.1:**
  - "Unified image generation and editing" in one 7B model, with native transparent output. — [DataNorth](https://datanorth.ai/news/qwen-releases-qwen-image-2-1)
  - mflux: img2img via `--image-path` / `--image-strength`; `mflux-generate-qwen-2.1-edit` for single or multi-reference instruction editing, prefix KV caching and RGBA. The VAE's alpha channel carries edit masks. — [mflux qwen21 README](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/qwen21/README.md)
  - diffusers has only `pipeline_qwenimage21.py`. — [diffusers](https://github.com/huggingface/diffusers/tree/main/src/diffusers/pipelines/qwenimage21)
- **Z-Image:**
  - diffusers has `z_image_img2img`, `_inpaint`, `_controlnet`, `_controlnet_inpaint` and `_omni`. — [diffusers z_image](https://github.com/huggingface/diffusers/tree/main/src/diffusers/pipelines/z_image)
  - mflux: img2img plus `mflux-generate-z-image-controlnet` using `alibaba-pai/Z-Image-Turbo-Fun-Controlnet-Union-2.1`. — [mflux z_image README](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/z_image/README.md)
  - Z-Image-Edit (natural-language image editing) and Z-Image-Omni-Base are still "To be released". — [Z-Image repo](https://github.com/Tongyi-MAI/Z-Image). `Tongyi-MAI/Z-Image-Edit` returned HTTP 401 on HF on 2026-10-11.
- **Krea 2:** strength-based img2img via `--image-path` / `--image-strength`. diffusers has only `pipeline_krea2`, which is text-to-image. — [mflux krea2 README](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/krea2/README.md); [diffusers](https://github.com/huggingface/diffusers/tree/main/src/diffusers/pipelines/krea2)
- **ERNIE-Image:** `--image-path input.jpg --image-strength 0.6` (0.0–1.0) img2img in mflux. diffusers has only text-to-image. — [mflux ernie_image README](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/ernie_image/README.md)
- **FLUX.1:**
  - mflux: `mflux-generate-fill --masked-image-path` for mask inpainting (FLUX.1-Fill-dev) and outpainting (via `tools/create_outpaint_image_canvas_and_mask.py --image-outpaint-padding "0,30%,20%,0"`), plus `-kontext` (instruction), `-redux` (image variation), `-depth`, `-controlnet` (Canny) and `-in-context(-edit / -catvton)` (virtual try-on). — [mflux flux README](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/flux/README.md)
  - diffusers has flux img2img, inpaint, fill, kontext, kontext_inpaint, control(img2img/inpaint), controlnet(img2img/inpainting) and prior_redux. — [diffusers flux](https://github.com/huggingface/diffusers/tree/main/src/diffusers/pipelines/flux)
- **Others:**
  - SD3.5: img2img and inpaint in diffusers. — [diffusers sd3](https://github.com/huggingface/diffusers/tree/main/src/diffusers/pipelines/stable_diffusion_3)
  - SDXL: img2img, inpaint and instruct_pix2pix. — [diffusers sdxl](https://github.com/huggingface/diffusers/tree/main/src/diffusers/pipelines/stable_diffusion_xl)
  - Chroma: img2img and inpainting. — [diffusers chroma](https://github.com/huggingface/diffusers/tree/main/src/diffusers/pipelines/chroma)
  - LongCat-Image: a dedicated Edit model with a diffusers `LongCatImageEdit` pipeline, also supported by sd.cpp. — [diffusers longcat_image](https://github.com/huggingface/diffusers/tree/main/src/diffusers/pipelines/longcat_image); [sd.cpp](https://github.com/leejet/stable-diffusion.cpp)
  - Bria FIBO: `bria_fibo_edit` pipeline; mflux says FIBO "has edit capabilities". — [diffusers](https://github.com/huggingface/diffusers/tree/main/src/diffusers/pipelines/bria_fibo); [mflux README](https://github.com/mflux-community/mflux)
  - Boogu: Boogu Image Edit is supported in sd.cpp. — [sd.cpp](https://github.com/leejet/stable-diffusion.cpp)
  - Ming-Image: a companion Ming-Image-0.1-Design-Layer model decomposes flat designs into editable layers. — [DataNorth](https://datanorth.ai/news/ant-group-releases-ming-image-0-1-design)
  - HiDream E1 / E1-1: instruction editing, Draw Things only. — [Draw Things](https://drawthings.ai/downloads/)

### Inferences
- A Lift editing UI needs these input types, mapped to mflux flags:
  - (a) Source image plus strength 0–1: `--image-path` / `--image-strength`. Generic across mflux models.
  - (b) Text instruction plus 1..N reference images: `--image-paths a b ...` on `*-edit` commands.
  - (c) Source plus binary mask: `mflux-generate-fill --masked-image-path` for FLUX.1-Fill, or diffusers `*_inpaint` pipelines for klein, Qwen and Z-Image.
  - (d) Outpaint: a padding spec, then a canvas and mask fed to Fill.
  - (e) Control image (Canny/depth/union): `*-controlnet`.
- Lift's `image_set` input type already fits multi-reference editing.

### Gaps
- I didn't verify the maximum number of reference images for klein or Qwen-Edit-2511.
- I didn't check whether mflux exposes inpainting masks for klein, Qwen or Z-Image. Only FLUX.1 Fill is confirmed in mflux, and the others are confirmed only as diffusers pipelines.
- I found no editing details for Ideogram 4, Lens or Boogu in mflux.

---

## Q8. Comparison and recommended recipe order

### Takeaway
Ship an **mflux-based recipe family first**: one pinned repo, a clean CLI, MLX speed and editing commands. Start with Z-Image Turbo and FLUX.2 klein 4B, both Apache and both fit on 16 GB. Add Qwen-Image-2512 + Edit-2511 for high-RAM Macs. Then add ERNIE-Image and a "high quality, non-commercial" tier (Qwen-Image-2.1, Krea 2).

### Cited Findings (comparison table; sources are those cited in Q1–Q7)

| Model | Params | Weights license (commercial?) | Gated | Mac path (evidence) | Clean CLI? | Editing | AA open Elo | RAM tier |
|---|---|---|---|---|---|---|---|---|
| Z-Image Turbo / base (Tongyi) | 6.15B | Apache-2.0 (yes) | No | mflux; sd.cpp; Draw Things; upstream `inference.py` picks MPS | mflux yes; upstream needs launcher (hard-coded prompt) | img2img, inpaint, ControlNet-Union (diffusers); img2img and ControlNet (mflux); instruction edit unreleased | 941 | 16 GB (q4/q6) |
| FLUX.2 [klein] 4B (BFL) | 3.88B | Apache-2.0 (yes) | No | mflux; sd.cpp; Draw Things | mflux yes; upstream CLI interactive and CUDA → diffusers launcher | t2i + single/multi-ref instruction edit, img2img (mflux `-edit`); mask inpaint (diffusers) | 863 | 16 GB |
| FLUX.2 [klein] 9B | 9.08B | FLUX NC (deploy needs paid license) | auto | mflux; sd.cpp; Draw Things | mflux yes | same as 4B, plus 9B-KV editing | 941 | 24–32 GB |
| Qwen-Image-2512 + Edit-2511 | 20.43B | Apache-2.0 (yes) | No | mflux; sd.cpp; Draw Things | mflux yes; upstream diffusers/Gradio only | instruction multi-image edit, img2img, inpaint, ControlNet, layered (diffusers); `qwen-edit` (mflux) | 889 (orig. Qwen Image) | 48–64 GB+ (TE ~14–15.5 GB bf16) |
| Qwen-Image-2.1 | 7.12B + 8B TE | Qwen Research (no) | No | mflux (M5 Max 78 s/40 steps); diffusers MPS ~85 s; sd.cpp; Draw Things | mflux yes | unified gen+edit, multi-ref, RGBA, img2img (mflux `-2.1-edit`) | **1036** (#1 open) | 64 GB (46 GB peak) |
| ERNIE-Image / Turbo (Baidu) | 8.03B | Apache-2.0 (yes) | No | mflux; sd.cpp; Draw Things | mflux yes | img2img strength only | 924 / 913 | 16–24 GB (q4 6.2 GB, q8 12 GB) |
| Krea 2 Turbo / Raw | 12.82B | Krea 2 Community (free <$1M / 50 seats; disputed) | auto | mflux; sd.cpp; Draw Things | mflux yes | img2img strength only | n/a | 24–32 GB (q8) |
| Ideogram 4 | 9.28B | Non-commercial | auto | mflux; sd.cpp; Draw Things | mflux yes | not documented | 1012 / 1004 | 24 GB+ (nf4) |
| Ming-Image-0.1-Design (Ant) | 6.15B + 16B MoE TE | MIT (yes) | No | mflux (M4 mini 1024² 4–4.5 min); sd.cpp | mflux yes | none in mflux; separate Layer decomposition model | 999 | 24 GB (q5) |
| Boogu Image 0.1 Turbo | 10.29B | Apache-2.0 (yes) | No | mflux; sd.cpp | mflux yes | Boogu Edit (sd.cpp) | n/a | 24 GB+ (est.) |
| Lens (Microsoft) | 3.8B + 20B TE | MIT per mirror; official repo 401 | ? | mflux; sd.cpp | mflux yes | not documented | n/a | 32 GB+ (est., 20B TE) |
| FIBO (Bria) | 8.29B | bria-fibo custom | auto | mflux | mflux yes | `bria_fibo_edit` (diffusers); mflux "has edit" | 881 | 24 GB+ (est.) |
| HiDream-O1-Image | 8.8B | MIT (yes) | No | sd.cpp (only Mac path found) | no (needs sd.cpp or launcher) | not researched | 982 | 24 GB+ (est.) |
| LongCat-Image / Edit (Meituan) | n/a | Apache-2.0 (yes) | No | sd.cpp | no | dedicated Edit model (diffusers, sd.cpp) | 861 | n/a |
| FLUX.2 [dev] | 32.22B | FLUX NC | auto | sd.cpp; Draw Things | no | multi-ref edit | 1000 | 64–128 GB (GGUF) |
| FLUX.1 [dev] / Kontext / Fill / Krea-dev | 11.9B | FLUX.1-dev NC | auto | mflux; sd.cpp; Draw Things | mflux yes (rich: fill, kontext, redux, controlnet) | img2img, mask inpaint, outpaint, instruction (Kontext), Redux, ControlNet, depth, try-on | 841 / 847 | 24–32 GB |
| FLUX.1 [schnell] | 11.89B | Apache-2.0 (yes) | auto | mflux; sd.cpp | mflux yes | img2img (legacy) | 803 | 24 GB |
| SD3.5 Large / Turbo / Medium | 8.15B / 2.47B | Stability Community (free <$1M) | auto | sd.cpp; Draw Things | no (diffusers launcher) | img2img, inpaint, SD3 ControlNet (diffusers) | 840 / 829 / 760 | 16–32 GB |
| SDXL 1.0 (+ finetunes) | 2.57B | openrail++ (yes, use restrictions) | No | sd.cpp | no | img2img, inpaint, instruct-pix2pix, ControlNet/IP-Adapter | 678 | 16 GB |
| Chroma1-HD | 8.9B | Apache-2.0 (yes) | No | sd.cpp; Draw Things | no | img2img, inpaint (diffusers) | n/a | 24 GB |
| PixArt-Sigma | 0.61B | openrail++ | No | sd.cpp | no | t2i only | n/a (superseded) | 8–16 GB |
| HiDream-I1 / E1-1 | 17.11B | MIT (yes) | No | Draw Things only (no Lift-usable path verified) | no | E1-1 instruction edit | 874 (I1-Dev) | 32 GB+ |

### Inferences: ranked shortlist
1. **Z-Image Turbo (via mflux `mflux-generate-z-image-turbo`).** Apache, 6B, 9 steps, runs on 16 GB at q4, best quality-per-GB among commercially clean models (Elo 941), very popular. Clean CLI in mflux. Upstream would need a ~20-line launcher because the prompt is hard-coded. Editing is limited to img2img and ControlNet for now.
2. **FLUX.2 [klein] 4B (via mflux `mflux-generate-flux2` + `mflux-generate-flux2-edit`).** Apache, fastest measured (~30 s at 1024² on an M1 Max), fits 16 GB, and has the best editing story for a small model (multi-reference instruction edit plus img2img). Make it the first editing-UI recipe. Upstream CLI is unusable (interactive, CUDA), so use mflux or a diffusers launcher.
3. **Qwen-Image-2512 + Qwen-Image-Edit-2511 (via mflux `mflux-generate-qwen` / `-qwen-edit`).** Apache, top text rendering, and the most capable commercially clean instruction editor. Limit it to 48–64 GB+ Macs: the text encoder isn't quantized, and the full download is ~58 GB.
4. **ERNIE-Image Turbo (via mflux `mflux-generate-ernie-image-turbo`).** Apache, 8B, q4 at 6.2 GB, strong text-rendering claims (GenEval 0.886), Elo 924. Cheap to add once the mflux family exists. img2img only.
5. **Qwen-Image-2.1 (via mflux `mflux-generate-qwen-2.1` / `-2.1-edit`), as a "best quality, personal use only" tier.** #1 open model on the arena with unified editing and RGBA, but under a research-only license and needing 64 GB. Krea 2 Turbo is the alternative pick here if its community license is confirmed as commercial under $1M.

- **Clean CLI vs. launcher:** all five have a clean CLI if Lift pins mflux. If Lift insists on pinning each model's own upstream repo, all five need a small diffusers or launcher script (Z-Image `inference.py` has no args; FLUX.2 `cli.py` is interactive and CUDA-only; Qwen and ERNIE are diffusers-only).
- **Lift design implication:** treat "mflux @ tag" as one community Mac port repo, in the same spirit as trellis-mac, with per-model recipes that differ only in the entry point, weights repo and settings schema. This also gives the editing UI uniform flags (`--image-path`, `--image-strength`, `--image-paths`, `--masked-image-path`).

### Gaps
- I didn't verify mflux's progress output format, whether mflux honors a pre-downloaded HF cache path that Lift controls (the README mentions "local model paths", not verified in detail), or whether Lift's recipe schema tolerates a non-PyTorch (MLX) venv.
- Krea 2's commercial terms are unconfirmed (sources conflict).

### Excluded (no Mac path)
No working Mac path found in this session (not proven impossible): HunyuanImage 3.0 / 3.0-Instruct (83B, ~169 GB repo), HunyuanImage 2.1, NVIDIA Cosmos3-Super-Text2Image (64.6B), GLM-Image, Lumina-Image 2.0, Sana / Sana-Sprint, Kolors (base), CogView4, Playground v2.5, OmniGen2, BAGEL, Janus-Pro.
