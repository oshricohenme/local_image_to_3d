# Apple Silicon Runtime Ecosystem for Local Generative Media (as it bears on Lift)

Research date: 2026-10-11. Anything dated before 2026 is marked "possibly outdated".

## 1. PyTorch MPS status (PyTorch 2.9–2.14): op gaps, dtypes, env vars

### Takeaway
MPS works for most diffusion and transformer inference in fp16/bf16. The hard, recurring blocker is **fp8 (float8_e4m3fn): MPS has no kernels for it**, so fp8 checkpoints fail outright. Other recurring problems are the 2^32-element NDArray limit, no float64, and NaNs in some video VAEs. PyTorch 2.11 and 2.12 improved op coverage and startup time. SDPA backward and performance work is still open.

### Cited Findings
- The stable docs now point to PyTorch **2.14**. The 2.13 MPS page was last updated 2026-05-11, and 2.13.0 was released 2026-07-08 — [PyTorch 2.13 MPS docs](https://docs.pytorch.org/docs/2.13/notes/mps.html); [Wikipedia](https://en.wikipedia.org/wiki/PyTorch); [2.14 env-var page](https://docs.pytorch.org/docs/2.14/mps_environment_variables.html)
- MPS needs macOS 14.0+ (from the error text in the docs snippet) — [PyTorch 2.13 MPS docs](https://docs.pytorch.org/docs/2.13/notes/mps.html)
- PyTorch 2.11 made MPS a headline item: broad operator expansion, new distribution functions, and asynchronous error reporting that catches out-of-bounds GPU indexing — [PyTorch 2.11 blog](https://pytorch.org/blog/pytorch-2-11-release-blog/)
- PyTorch 2.12 ships Apple Silicon wheels with ahead-of-time compiled Metal-4 shaders, so first runs no longer pay for runtime shader compilation (PR #179378) — [PyTorch 2.12 blog](https://pytorch.org/blog/pytorch-2-12-release-blog/)
- An open issue (work started April 2026) tracks MPS SDPA improvements: moving call-site logic into the MPS implementation and adding a dedicated backward pass — [pytorch#179294](https://github.com/pytorch/pytorch/issues/179294)
- **fp8 is unsupported.** The official LTX-2 PyTorch nodes need CUDA for the fp8 checkpoints because "PyTorch's MPS backend has no kernel support for the float8_e4m3fn dtype" — [comfyui-ltx2-mlx extension](https://comfy.icu/extension/tanis2000__comfyui-ltx2-mlx). A hands-on test (M1 Max, March–May 2026) got `RuntimeError: Undefined type Float8_e4m3fn`, also with a Gemma fp4-mixed text encoder — [lilting.ch](https://lilting.ch/en/articles/ltx2-wan22-mac-local-video-gen). ComfyUI users see "Trying to convert Float8_e4m3fn to the MPS backend but it does not have support for that dtype". A community ComfyUI-AppleSilicon-FP8 project claims a workaround (unverified) — [ComfyUI-AppleSilicon-FP8](https://github.com/pawel-mazurkiewicz/ComfyUI-AppleSilicon-FP8)
- **Dtypes:** MPS supports float32, float16 and (in newer versions) bfloat16, but not float64 — [Lightning issue #21261](https://github.com/Lightning-AI/pytorch-lightning/issues/21261). Older "BFloat16 is not supported on MPS" errors came from Intel/AMD Macs and were closed as not planned (possibly outdated, and not relevant to Apple Silicon) — [pytorch#141864](https://github.com/pytorch/pytorch/issues/141864)
- **Size limit:** "The PyTorch mps backend does not support NDArray sizes greater than 2**32" — [diffusers MPS docs](https://huggingface.co/docs/diffusers/optimization/mps). A PyTorch PR comment ties an FP16 failure to a tensor too large for an MPS copy-cast — [pytorch PR #133430](https://github.com/pytorch/pytorch/pull/133430)
- **Video VAE NaNs:** the official LTX-2 two-stage pipeline produced `invalid value encountered in cast` at VAE decode on MPS (a one-frame, 17 KB output) — [lilting.ch](https://lilting.ch/en/articles/ltx2-wan22-mac-local-video-gen)
- **Environment variables** (PyTorch 2.14 docs) — [MPS env vars](https://docs.pytorch.org/docs/2.14/mps_environment_variables.html):
  - `PYTORCH_ENABLE_MPS_FALLBACK=1`: unsupported ops fall back to CPU.
  - `PYTORCH_MPS_HIGH_WATERMARK_RATIO`: hard allocation cap as a multiple of `recommendedMaxWorkingSetSize`. Default 1.7. `0.0` disables the limit ("may cause system failure"). Allocations past the cap fail with OOM.
  - `PYTORCH_MPS_LOW_WATERMARK_RATIO`: soft target that triggers garbage collection and adaptive commit. Default 1.4 on unified memory. `0.0` disables it.
  - `PYTORCH_MPS_FAST_MATH=1`
  - `PYTORCH_MPS_PREFER_METAL=1`: use Metal kernels instead of MPSGraph for matmul.
  - `PYTORCH_DEBUG_MPS_ALLOCATOR`, `PYTORCH_MPS_LOG_PROFILE_INFO`, `PYTORCH_MPS_TRACE_SIGNPOSTS`: debugging and profiling.
- A Conv3d/bf16 regression in 2.9.x was reported on **CUDA**, not MPS — [pytorch#168167](https://github.com/pytorch/pytorch/issues/168167); [pytorch#166643](https://github.com/pytorch/pytorch/issues/166643)

### Inferences
- Lift's shim should treat fp8 as "convert on load to bf16/fp16, or pick a non-fp8 checkpoint". The recipe should pin a bf16 or GGUF variant of the weights instead of the repo's default fp8 file.
- Set `PYTORCH_ENABLE_MPS_FALLBACK=1` by default. A silent CPU fallback beats a crash for non-developers, but it can make runs very slow, so log the fallback warnings and show them in Lift.
- Leave the high watermark at its default. Setting it to 0.0 risks freezing the whole machine, which is worse for non-developers than a clean OOM error Lift can explain ("this model needs a Mac with more memory").
- With Metal-4 AOT shaders (2.12+), pinning PyTorch ≥2.12 should remove the slow first run that confuses users.

### Gaps
- I found no authoritative per-op list of MPS ops still missing in 2.13/2.14. The public "MPS op coverage tracker" content was not retrieved.
- I found no data on Conv3d speed on MPS, SDPA throughput vs MLX, or torch.compile maturity for MPS (likely still limited, but unsourced).
- I could not retrieve the 2.13 or 2.14 release notes for their MPS-specific changes.

## 2. MLX multi-model packages a recipe could wrap

### Takeaway
MLX packages are now the strongest Mac path. **mflux** (MIT) covers about 14 image-model families, including FLUX.1/2, Qwen-Image/2.1, Z-Image, Krea 2, ERNIE and SeedVR2 upscaling, plus editing. **mlx-video** (MIT, Blaizzy) covers LTX-2/2.3 and Wan2.1/2.2. **mlx-audio** (MIT, Blaizzy) covers dozens of TTS and STT models plus MiniMax Music 3. **DiffusionKit was archived on 2026-03-21** and should not be used.

### Cited Findings
- **mflux** — [GitHub](https://github.com/filipstrand/mflux) (now also under mflux-community):
  - "Apple MLX native implementations of state-of-the-art generative image & video models". MIT license. Line-by-line MLX ports of Diffusers/Transformers implementations.
  - Model table: Z-Image (6B), Krea 2 (12B, Jun 2026), FLUX.2 (4B and 9B Klein, Jan 2026), Ideogram 4 (9B), ERNIE-Image (8B), Lens, Ming-Image (Sep 2026), Boogu Image, FIBO, SeedVR2 (3B/7B upscaler), Qwen Image (20B), Qwen Image 2.1 (Sep 2026), Depth Pro, FLUX.1 (12B).
  - Per-model CLIs, e.g. `mflux-generate-z-image-turbo`. `mflux-capabilities` gives a "machine-readable option contract". Quantization via `-q 8` / `quantize=8`. Multi-LoRA. Also installs on NVIDIA DGX.
- mflux v0.21.0 (the latest shown is v0.22.0), for `mflux-generate-qwen-2.1-edit` — [release notes](https://newreleases.io/project/github/mflux-community/mflux/release/v.0.21.0):
  - New flags: `--mask-image`, `--auto-mask`, `--strength`, `--enhance-prompt`, `--verify`, `--use-step-cache`.
  - `--scheduler viggle_turbo --steps 6` runs a 6-step generation or edit.
  - Qwen-Image-2.1 is up to about 1.8x faster.
  - `--low-ram` frees the transformer before VAE decode.
- mflux capabilities also include image-to-image (Flux, Qwen, Z-Image Turbo, FIBO), Kontext, in-context/reference editing, CATVTON, Redux, ControlNet Canny, depth, fill/inpainting, Flux2 Edit and Qwen Edit (multi-image), SeedVR2 upscaling, and `--stepwise-image-output-dir` — [mflux-cli skill summary](https://tessl.io/registry/skills/github/mflux-community/mflux/mflux-cli)
- **mlx-video** (Blaizzy) — [GitHub](https://github.com/Blaizzy/mlx-video):
  - MIT license. Requires MLX ≥0.22, Python ≥3.11, and PyTorch only for weight conversion.
  - Models: LTX-2 (19B; T2V, I2V, A2V, joint audio-video; pipelines distilled, dev, dev-two-stage, dev-two-stage-hq), Wan2.1 (1.3B/14B T2V), Wan2.2 (T2V-14B, TI2V-5B, I2V-14B).
  - CLIs: `mlx_video.ltx_2.generate` (`--pipeline --image --audio-file --cfg-scale --model-repo`) and `mlx_video.wan_2.generate` (`--model-dir --steps --guide-scale --shift --lora-high --lora-low`).
  - Wan needs a conversion step first (`mlx_video.convert_wan`). Pre-converted LTX-2/2.3 weights exist in prince-canuma HF repos. Supports the Wan2.2-Lightning 4-step LoRA.
- Other LTX MLX ports:
  - Acelogic/LTX-2-MLX supports LTX-2.0 (19B) and LTX-2.3 (22B), about 25 GB RAM minimum — [Acelogic/LTX-2-MLX](https://gitblind.noratr.app/Acelogic/LTX-2-MLX)
  - LTX-2.3 22B distilled fp16 MLX is about 66 GB and needs a 64 GB Mac; a 4-bit build fits 32 GB Macs — [HF LTX-2.3-MLX](https://huggingface.co/FrankDase/LTX-2.3-MLX)
  - An LTX-2.5 MLX conversion was tested on an M4 64 GB and needs MLX ≥0.31 — [HF LTX-2.5-MLX](https://huggingface.co/FrankDase/LTX-2.5-MLX)
  - A SwiftUI app wraps LTX on MLX — [ltx-video-mac](https://www.sourcepulse.org/projects/29781140)
- **mlx-audio** (Blaizzy) — [GitHub](https://github.com/Blaizzy/mlx-audio):
  - MIT license.
  - TTS: Kokoro, KittenTTS, Qwen3-TTS, Higgs Audio v2/v3, OmniVoice, CSM, Dia, OuteTTS, Spark, Chatterbox, Soprano, Ming Omni TTS, Voxtral TTS, VoxCPM2, MeloTTS, MOSS-TTS, and more.
  - STT: Whisper, Distil-Whisper, Qwen3-ASR, Parakeet, Nemotron, Voxtral, Canary, Moonshine, Granite Speech, and more.
  - VAD and diarization: Silero, Sortformer.
  - Speech-to-speech and enhancement: SAM-Audio, MossFormer2 SE, DeepFilterNet, and more.
  - **Music:** MiniMax Music 3 (songs with lyrics, 44.1 kHz stereo).
  - CLI: `mlx_audio.tts.generate --model --text --voice --lang_code --output_path --stream --join_audio --ref_audio`
  - OpenAI-compatible server: `mlx_audio.server`, serving `/v1/audio/speech` and `/v1/audio/transcriptions`.
  - Quantization: `mlx_audio.convert --quantize --q-bits` (3/4/6/8-bit; modes affine/mxfp4/mxfp8/nvfp4).
- mlx-audio 0.4.3 was released 2026-04-28 on PyPI, with commits through June 2026 — [CERN PyPI mirror](https://simple-repository.app.cern.ch/project/mlx-audio); [jsDelivr README](https://cdn.jsdelivr.net/gh/blaizzy/mlx-audio@main/README.md)
- **DiffusionKit** (Argmax) — [GitHub](https://github.com/argmaxinc/DiffusionKit):
  - Models: SD3 medium, FLUX.1-dev, FLUX.1-schnell.
  - CLI: `diffusionkit-cli --prompt --image-path --denoise --height --width --seed --local-ckpt`. No mask support mentioned.
  - MIT license. **"Archived by the owner on Mar 21, 2026. It is now read-only."**
- **Speed (Apple's figure):** FLUX-dev-4bit (12B) at 1024x1024 with MLX is ">3.8x faster on a M5 than on a M4" — [Apple ML Research](https://machinelearning.apple.com/research/exploring-llms-mlx-m5). MacSparky reports that figure was measured on a base M5 with 24 GB — [MacSparky](https://www.macsparky.com/blog/2026/01/the-m5-pro-and-max-are-going-to-be-monsters-for-local-ai/)
- One guide argues MLX-native tools "exploit Apple silicon more directly", while PyTorch MPS / ComfyUI speed "can vary by model and node" — [ModelFit](https://modelfit.io/guides/local-image-generation-mac/)

### Inferences
- A single mflux recipe "pattern" (pin the mflux version, run `mflux-generate-<model>`) can cover a dozen image models. Lift can read `mflux-capabilities` to build typed settings automatically, which fits "packages over custom code".
- mlx-video's Wan path needs a conversion step. Lift's installer would run `convert_wan` once after the weights download. This is a recipe "post-download step", not custom code.
- mlx-audio is effectively the one-stop audio runtime (TTS, STT, music, enhancement). It also has a server mode if Lift ever wants a persistent process.
- The Neural Accelerators in the M5 family are used by MLX (Apple's measurement), which is another reason to prefer MLX recipes on M5 Macs.

### Gaps
- I found no head-to-head mflux vs PyTorch-MPS timing on the same Mac.
- I could not confirm mflux's full list of `--image-path`/fill flags per model from the README. Lift should read them from `mflux-capabilities` / `--help`.
- I found no data on whether mlx-examples (Apple) is still the place for MusicGen or SD. It appears superseded by mflux and mlx-audio, but this is unsourced.
- mlx-vlm was not researched; it is out of scope for generation.

## 3. Hugging Face diffusers on MPS

### Takeaway
Diffusers officially supports `mps` through `.to("mps")`. The docs page is thin and dated: it targets M1/M2, recommends attention slicing below 64 GB, and warns about batching and the 2^32 limit. A generic diffusers launcher is feasible, because pipelines share `image`/`mask_image`/`strength` kwargs, but it falls outside Lift's "run the upstream repo's own CLI" model.

### Cited Findings
- Requirements on the docs page: macOS 12.6+ (13+ recommended), arm64 Python, PyTorch 2.0 recommended. The page still names M1/M2 (possibly outdated) — [diffusers MPS docs](https://huggingface.co/docs/diffusers/optimization/mps)
- "Recommended if your computer has < 64 GB of RAM: `pipe.enable_attention_slicing()`". On Apple silicon, slicing gives "better performance in most Apple silicon computers unless you have 64GB of RAM or more" because "performance is very sensitive to memory pressure" and swapping — [diffusers MPS docs](https://huggingface.co/docs/diffusers/optimization/mps)
- "Generating multiple prompts in a batch can crash or fail to work reliably… try iterating instead of batching" — [diffusers MPS docs](https://huggingface.co/docs/diffusers/optimization/mps)
- Pipelines carry an MPS badge when they can use MPS — [diffusers MPS docs](https://huggingface.co/docs/diffusers/optimization/mps)
- Diffusers 0.35.0 added Qwen Image pipelines, Flux Kontext, and Wan 2.2 — [newreleases diffusers 0.35.0](https://newreleases.io/project/pypi/diffusers/release/0.35.0)
- PyTorch 2.0+ SDPA is automatically enabled, so xFormers is unnecessary — [diffusers inpaint docs](https://huggingface.co/docs/diffusers/using-diffusers/inpaint)

### Inferences
- `enable_model_cpu_offload()` gains little on unified memory, because CPU and GPU share the same RAM. Attention slicing, VAE tiling and smaller dtypes are the relevant tools. This is inferred from the architecture; I found no source on its behaviour on unified memory.
- A "diffusers launcher" recipe (one small script that takes `--pipeline-id --prompt --image --mask --strength`) could cover many models. It is the one place where Lift would own runtime code, and it duplicates what mflux already does natively and faster for image. Use it only for models mflux lacks.

### Gaps
- I found no official list of which current pipelines (Wan, Qwen-Image, LTX, HunyuanVideo) are tested on mps.
- I found no source on how `enable_model_cpu_offload` behaves on mps.

## 4. Quantization on Mac (GGUF, MLX 4/8-bit, quanto, torchao)

### Takeaway
Two quantization routes work on a Mac. **MLX 4/8-bit** goes through mflux `-q`, mlx-audio `--q-bits` and pre-quantized LTX MLX builds. **GGUF** goes through stable-diffusion.cpp or ComfyUI-GGUF. Both let 24–32 GB Macs run 12–22B image and video models. fp8 is not an option on MPS.

### Cited Findings
- FLUX-dev-4bit (12B) runs on a base M5 24 GB with MLX — [Apple ML Research](https://machinelearning.apple.com/research/exploring-llms-mlx-m5); [MacSparky](https://www.macsparky.com/blog/2026/01/the-m5-pro-and-max-are-going-to-be-monsters-for-local-ai/)
- LTX-2.3 22B: fp16 about 66 GB needs 64 GB RAM; 4-bit fits 32 GB — [HF LTX-2.3-MLX](https://huggingface.co/FrankDase/LTX-2.3-MLX)
- An 8-bit MLX Wan2.2 TI2V-5B "runs comfortably at 720p (1280×704), 24fps on a 64 GB" Mac, while the 14B dual-model I2V "struggles" (one user's report) — [HF Wan2.2-TI2V-5B-mlx-q8](https://huggingface.co/Anes1032/Wan2.2-TI2V-5B-mlx-q8)
- GGUF Wan 2.2 14B: high and low noise Q4_K_S at 8.75 GB each, umt5-xxl Q8_0 at 6.04 GB, about 24 GB total. Ran on an M1 Max 64 GB under ComfyUI-GGUF — [lilting.ch](https://lilting.ch/en/articles/ltx2-wan22-mac-local-video-gen)
- stable-diffusion.cpp: "ensure your total usable memory (RAM + VRAM / unified) is larger than the GGUF size" — [Unsloth Qwen-Image-2512 sd.cpp guide](https://unsloth.ai/docs/models/qwen-image-2512/stable-diffusion.cpp)
- stable-diffusion.cpp reads `.gguf`/`.safetensors`, has a convert mode, and an "INT8 convrot safetensors" option — [stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp)
- mlx-audio quantization modes are affine/mxfp4/mxfp8/nvfp4 at 3/4/6/8 bits — [mlx-audio](https://github.com/Blaizzy/mlx-audio)

### Inferences
- Qwen-Image 20B at 4-bit (about 10–12 GB of weights) plus its text encoder probably fits 32 GB. At 8-bit it wants 48 GB or more. This is estimated from parameter counts, not measured.
- Wan 14B on a 16–32 GB Mac is technically possible with GGUF Q4 but impractically slow (see section 8). The TI2V-5B is the realistic Wan for most users.

### Gaps
- I found no sources on optimum-quanto or torchao running on MPS in 2026, nor on city96 ComfyUI-GGUF Mac-specific performance beyond the single report above.

## 5. Native / non-Python engines

### Takeaway
**stable-diffusion.cpp** (MIT, C/C++, Metal backend, `sd-cli`) has the broadest single-binary model coverage. As of September 2026 it handles image (FLUX.1/2, Qwen-Image/2.1, Z-Image, Krea2, etc.) and video (Wan2.1/2.2, LTX-2.3/2.5, HunyuanVideo 1.5). It is a strong fallback engine. Draw Things is the fastest Mac app but has no documented Mac CLI; it exposes a gRPC server. Core ML Stable Diffusion and whisper.cpp were not researched in depth.

### Cited Findings
- stable-diffusion.cpp — [GitHub](https://github.com/leejet/stable-diffusion.cpp):
  - Image models: SD1.x/2.x/XL/3.5, FLUX.1, FLUX.2-dev/klein, Chroma, Qwen Image/2.1, Z-Image, ERNIE-Image, Krea2, Ideogram4, HiDream-O1, and more.
  - Edit models: FLUX.1-Kontext, the Qwen Image Edit series, and others.
  - Video: Wan2.1/2.2, LTX-2.3/2.5, HunyuanVideo 1.5, MiniMax-H3.
  - Backends: CPU, CUDA, Vulkan, Metal, OpenCL, SYCL.
  - CLI: `sd-cli -m <model> -p <prompt>`. MIT license. Latest news 2026-09-20 (Qwen-Image-2.1 day-0 support). Has an embedded web UI (2026-04-11).
  - The README warns the "API and command-line option may change frequently".
- Unsloth's sd.cpp guide is CUDA-focused, but says Apple/CPU build "instructions… are similar and available in the repo" — [Unsloth](https://unsloth.ai/docs/models/qwen-image-2512/stable-diffusion.cpp)
- Draw Things exposes an API server over gRPC (port 7859, TLS, compression) via Advanced Settings. `gRPCServerCLI` is documented for Linux Docker (with nvidia-container-toolkit); I found no Mac CLI syntax — [draw-things-chat deployment docs](https://lmstudio.ai/ceveyne/draw-things-chat/files/docs/DEPLOYMENT.md)
- Draw Things reports more than 3.3x speed-up on M5 Max over M4 Max ("Lightning Draft") — [Draw Things release](https://releases.drawthings.ai/p/introducing-lightning-draft-interactive). Apple says Draw Things on the M5 iPad Pro is up to 4x faster than M4 for Qwen-image and Flux — [Apple tech talk](https://developer.apple.com/jp/videos/play/tech-talks/111432/)
- Users report Draw Things' official Wan2.1 models crashing after generation on an M4 (Reddit, anecdotal) — [r/drawthingsapp](https://redlib.ssps.io/r/drawthingsapp)

### Inferences
- sd.cpp fits Lift as a "native binary recipe": pin a release, build or download a Metal binary, download GGUF weights, and run `sd-cli`. No Python, no PyTorch, no CUDA shim. The trade-off is that progress parsing and flags change often, so the pin matters.
- Draw Things is not an "unmodified upstream repo" Lift can package. Its gRPC needs the app running, so it is not a recipe target.

### Gaps
- I found no sd.cpp vs mflux speed comparison on Mac.
- Licensing details for Draw Things' server were not found.
- Apple Core ML Stable Diffusion maintenance status and whisper.cpp were not researched. whisper.cpp is likely redundant given mlx-audio Whisper.

## 6. ComfyUI on Apple Silicon as a backend

### Takeaway
ComfyUI runs on MPS and supports GGUF, but it inherits every MPS limit: fp8 fails, video is very slow, and the official LTX-2 pipelines fail on MPS. Wrapping it means shipping workflow JSONs and custom nodes, which conflicts with Lift's "run the upstream repo's own CLI" principle. It is not recommended as a general backend.

### Cited Findings
- An M1 Max 64 GB under ComfyUI ran Wan 2.2 GGUF in **82 min for a 2 s clip** (832x480, 33 frames). LTX-2's official two-stage pipeline NaN'd on MPS, and fp8 failed. The author concludes proper LTX-2 video on Mac via this route is "currently not feasible" — [lilting.ch](https://lilting.ch/en/articles/ltx2-wan22-mac-local-video-gen)
- A community test found ComfyUI about 20% slower than Draw Things on the same M4 Pro Mac mini — [ModelFit](https://modelfit.io/guides/local-image-generation-mac/)
- Community MPS-specific nodes exist: an MPS-Accelerate node claims 22% faster Flux.1-Dev; an fp8 workaround node also exists (both unverified) — [Reddit snapshot](https://reddit.sentinel-team.org/posts/1rxr165/snapshots/2026-03-20T17%3A36%3A49.07391Z); [ComfyUI-AppleSilicon-FP8](https://github.com/pawel-mazurkiewicz/ComfyUI-AppleSilicon-FP8)
- ComfyUI wrappers of MLX ports exist, e.g. comfyui-ltx2-mlx wrapping dgrauet/ltx-2-mlx — [comfy.icu](https://comfy.icu/extension/tanis2000__comfyui-ltx2-mlx)

### Inferences
- If Lift ever needs ComfyUI, treat it as one recipe (pinned ComfyUI commit + pinned workflow JSON + pinned custom nodes, driven over the headless HTTP API), not as the platform. The MLX-native packages make it largely unnecessary.

### Gaps
- I found no source on ComfyUI headless API stability on Mac or its Mac memory behaviour.

## 7. Recurring CUDA-only dependencies and Mac substitutes

### Takeaway
The recurring blockers are flash-attn, xformers, triton, sageattention, bitsandbytes, apex, deepspeed, decord and fp8 weights. Most attention libraries map cleanly to PyTorch SDPA. decord maps to PyAV. Quantization libraries (bitsandbytes) have no MPS equivalent and need no-op or dequantized stand-ins.

### Cited Findings
- PyTorch 2.0+ SDPA is used automatically, so xFormers memory-efficient attention is unnecessary — [diffusers inpaint docs](https://huggingface.co/docs/diffusers/using-diffusers/inpaint)
- **decord:** the PyPI decord 0.6.0 does not work on Apple Silicon (secondary source) — [CSDN](https://aicoding.csdn.net/6a69ce2c662f9a54cb95e2f9.html). A community arm64 wheel exists but needs Homebrew ffmpeg@4 at a specific path — [AppleSiliconSelfBuilds](https://github.com/wizyoung/AppleSiliconSelfBuilds)
- **PyAV** ships binary wheels for macOS linked against the latest ffmpeg — [PyPI av](https://pypi.org/project/av)
- **torchcodec** needs a source build on macOS and breaks with Homebrew ffmpeg (conda-forge ffmpeg works) — [PyPI TorchCodec](https://pypi.org/project/TorchCodec); [torchcodec#570](https://github.com/meta-pytorch/torchcodec/issues/570)
- fp8 dtype: see section 1 — [comfyui-ltx2-mlx](https://comfy.icu/extension/tanis2000__comfyui-ltx2-mlx)

### Inferences
Suggested shim mapping. This is extrapolated from the SDPA/PyAV findings and the Lift context; I found no single source listing it.

| CUDA-only dependency | Shim stand-in |
|---|---|
| `flash_attn` / `xformers.ops.memory_efficient_attention` / `sageattention` | `torch.nn.functional.scaled_dot_product_attention` wrappers with matching signatures. Handle varlen/packed variants by unpacking. |
| `triton` | Import stub so `import triton` succeeds; code paths behind `@triton.jit` must have a torch fallback or the recipe needs a port. |
| `bitsandbytes` | `Linear8bitLt`/`Linear4bit` become plain `nn.Linear` in fp16/bf16, i.e. ignore the quantization request. |
| `apex` | FusedLayerNorm/FusedAdam become torch equivalents. |
| `deepspeed` | Inference-only no-op. |
| `decord.VideoReader` | Adapter over PyAV. |
| fp8 safetensors | Upcast to bf16 at load time, or prefer bf16/GGUF variants in the recipe. |

Environment defaults for the shim: `PYTORCH_ENABLE_MPS_FALLBACK=1`, and code that ignores `.cuda()` calls by remapping `"cuda"` to `"mps"`.

### Gaps
- I found no sourced survey of how often each dependency appears across 2026 media repos.
- I found no sources on `spconv` or `sageattention` Mac substitutes specifically.

## 8. Real-world throughput benchmarks (M2/M3/M4/M5)

### Takeaway
Reliable cross-chip benchmarks are scarce. Image generation is practical on all Max/Ultra chips, and the M5 generation is roughly 3–4x faster than M4 for image diffusion under MLX and Draw Things. Video on pre-M5 Macs via PyTorch/ComfyUI is very slow; MLX ports are the main hope.

### Cited Findings
- FLUX-dev-4bit at 1024²: M5 is >3.8x faster than M4 (MLX, Apple) — [Apple ML Research](https://machinelearning.apple.com/research/exploring-llms-mlx-m5)
- Draw Things: M5 Max >3.3x over M4 Max — [Draw Things](https://releases.drawthings.ai/p/introducing-lightning-draft-interactive). MaxTech (via MacRumors forum) measured about 2.2x for vanilla M4 vs M5 in Draw Things — [MacRumors](https://forums.macrumors.com/threads/m4m-and-m3u-for-image-generation-speed-sd-flux-etc.2454524/)
- Apple claims text-to-image gains of up to 3.5x (M5 Max) and 4.3x (M5 Ultra); these are vendor numbers — reported by [kingy.ai](https://kingy.ai/blog/mac-studio-m5-local-ai-buying-guide/)
- FLUX 1024²: M4 Max 85 s, M3 Max 105 s, M2 Max 145 s. App, model and step count are unspecified, and the source is a 2025 guide (possibly outdated) — [Apatero](https://www.apatero.com/blog/flux-apple-silicon-m1-m2-m3-m4-complete-performance-guide-2025)
- Video on M1 Max 64 GB (ComfyUI, GGUF) — [lilting.ch](https://lilting.ch/en/articles/ltx2-wan22-mac-local-video-gen):
  - Wan 2.2 14B: about 250 s/step, 82 min per 2 s clip.
  - LTX-2 dev GGUF: 14.7 s/step at 512x288; 30.8 s/step at 768x512.
  - Cited reports: LTX-2 about 5 min on M3; about 15 min on M1 16 GB.
- M5 Pro/Max MacBook Pros shipped March 2026 with up to 128 GB — reported in [lilting.ch search summary / guide](https://lilting.ch/en/tags/Apple%20Silicon)

### Inferences
- Lift should show realistic time estimates per chip generation, and probably gate video recipes as "M3 Max or newer recommended", based on how slow the M1 Max results are.

### Gaps
- I found no measured mflux, mlx-video or mlx-audio timings on M4 Max/Ultra or M5 Max from independent sources.
- I found no measured Wan 2.2 times on M4/M5.
- I found no audio (TTS/music) throughput numbers.

## 9. Recommendations for Lift (patterns, shim, memory tiers, editing inputs)

### Takeaway
Support four recipe patterns, in priority order:
1. **MLX package CLI**: mflux, mlx-video, mlx-audio.
2. **Upstream repo + MPS + shim**: Lift's current pattern.
3. **Community Mac port**: e.g. trellis-mac, LTX-2-MLX.
4. **Native binary**: stable-diffusion.cpp `sd-cli`.

Treat a diffusers launcher and ComfyUI as optional last resorts. Standardize editing inputs in the recipe schema as: source image, mask (canonical grayscale, white = edit), strength 0–1, a list of reference images, and a reference audio. Each recipe maps these to its runtime's flags and converts mask polarity.

### Cited Findings
Evidence for the editing-input mapping, per runtime:
- **mflux:**
  - img2img uses `--image-path` + `--image-strength`. A community note says strength is silently ignored without an explicit value; one contributor claims 0.0 = ignore the reference and 1.0 = keep it (unverified) — [linuxcommandlibrary mflux](https://linuxcommandlibrary.com/man/mflux); [community PR](https://zff.dev/CryptoJones/MacminiM2Pro_LocalModelConfig/pulls/8)
  - Qwen-2.1 edit uses `--mask-image`, `--auto-mask` and `--strength`, and accepts up to 10 reference images. **Mask transparency = "preserve"**, and reference images with transparency are composited over white — [mflux v0.21.0](https://newreleases.io/project/github/mflux-community/mflux/release/v.0.21.0)
  - Fill/inpaint, Kontext, Redux, in-context, CATVTON and Flux2/Qwen multi-image edit all exist — [mflux-cli](https://tessl.io/registry/skills/github/mflux-community/mflux/mflux-cli)
- **DiffusionKit:** `--image-path` + `--denoise` (0–1). No mask. Archived 2026-03-21 — [DiffusionKit](https://github.com/argmaxinc/DiffusionKit)
- **diffusers:**
  - Inputs: `image`, `mask_image`, `strength`, `padding_mask_crop`.
  - Mask convention: **white = inpaint, black = keep**.
  - `mask_processor.blur(mask, blur_factor)` feathers the mask edge. `image_processor.apply_overlay(mask, init, out)` forces unmasked pixels to stay unchanged.
  - Higher `strength` means more noise and more change, and strength also scales the effective number of steps. Controlnet inpaint treats mask >0.5 as masked.
  - [diffusers inpaint docs](https://huggingface.co/docs/diffusers/using-diffusers/inpaint)
- **mlx-video:** source image for I2V via `--image`; source audio for A2V via `--audio-file`; LoRA via `--lora-high/--lora-low` — [mlx-video](https://github.com/Blaizzy/mlx-video)
- **mlx-audio:** reference voice via `--ref_audio` (voice cloning); separate speech-to-speech/enhancement models (SAM-Audio, MossFormer2 SE, DeepFilterNet) — [mlx-audio](https://github.com/Blaizzy/mlx-audio)
- **stable-diffusion.cpp:** supports edit models (Kontext, Qwen Image Edit), ControlNet and IP-Adapter. Its flags were not documented on the README page — [stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp)

### Inferences
**(a) Recipe patterns**
1. **MLX package CLI.** Pin the package version, `uv tool install`, call a per-model command.
   - Default for image (mflux), audio (mlx-audio) and LTX/Wan video (mlx-video). Fastest on M5, no CUDA shim, MIT licensed.
   - Use `mflux-capabilities` to generate typed settings.
   - Supports an optional post-download "convert" step (mlx-video Wan).
2. **Upstream repo + MPS + shim.** Lift's existing model, for models with no MLX port: 3D, niche video and audio repos.
3. **Community Mac port.** The same mechanics as pattern 2, pinned to the fork's commit.
4. **Native binary (sd.cpp).** Broadest GGUF coverage; the route for 16–24 GB Macs that need heavy quantization. Pin the release, since flags change often.
5. **Avoid as platforms:** a diffusers launcher (it is Lift-owned code; use only if a model has a diffusers pipeline but no MLX port or usable CLI), ComfyUI, Draw Things and DiffusionKit (archived).

**(b) Recurring blockers and shim handling**

| Blocker | Handling |
|---|---|
| fp8 weights | Pick bf16/GGUF/MLX-quantized variants in the recipe manifest; the shim upcasts fp8 tensors at load as a last resort. |
| flash-attn / xformers / sageattention | SDPA stand-ins. |
| triton | Import stub. |
| bitsandbytes | Dequantized nn.Linear. |
| apex / deepspeed | Torch equivalents or no-ops. |
| decord | PyAV adapter. |
| CUDA device strings | Remap to `mps`. |
| Missing ops | `PYTORCH_ENABLE_MPS_FALLBACK=1`, with warnings surfaced in Lift. |
| OOM | Keep the default watermark (1.7) and translate the OOM error into plain language with a "needs N GB" message. |
| 2^32-element tensors / video VAE NaNs | Per-recipe caps on resolution and frames, plus tiled VAE decode where the repo offers it. |
| Batching instability | Force batch size 1. |

**(c) Minimum memory tiers** (best estimate from the cited fit data; verify per recipe)

| Media type | 16 GB | 24–32 GB | 48–64 GB | 96–128 GB |
|---|---|---|---|---|
| Image | Small models (Z-Image 6B, FLUX.2 Klein 4B) quantized 4/8-bit via mflux | FLUX.1 12B at 4-bit (Apple ran it on 24 GB), FLUX.2 9B, Qwen-Image 20B at 4-bit (est.) | Qwen-Image at 8-bit, unquantized 12B models | — |
| Video | Not recommended | LTX-2.3 4-bit (fits 32 GB); Wan2.2 TI2V-5B quantized (slow) | LTX fp16 (66 GB build needs 64 GB); Wan2.2 TI2V-5B 720p comfortable at 64 GB | Wan 14B dual-model (still "struggles" at 64 GB per one report) |
| Audio | Fine for TTS/STT (Kokoro 82M, Whisper, Qwen3-TTS) | Larger TTS (Higgs, Ming Omni 16.8B quantized) and MiniMax Music 3 likely want 24–32 GB+ (unverified) | — | — |

**(d) Editing-input schema** to standardize across recipes:
- `source_image`: PNG, RGB. Maps to mflux `--image-path`, DiffusionKit `--image-path`, diffusers `image=`, mlx-video `--image`.
- `mask`: Lift stores a single-channel PNG at source resolution, **white (255) = regenerate, black (0) = keep**, matching diffusers. Recipes declare `mask_format`:
  - `diffusers_bw`: pass as is.
  - `alpha_preserve`: for mflux Qwen-2.1 edit, where transparency = preserve. Lift converts: edit region becomes opaque, keep region transparent. This mapping is inferred; verify against `--help`.
  - Optional `mask_feather` (diffusers blur_factor) and `preserve_unmasked` (diffusers apply_overlay).
- `strength`: a 0–1 float with the same meaning everywhere (1 = ignore the source). Maps to mflux `--image-strength`/`--strength` and DiffusionKit `--denoise`. Direction on mflux `--image-strength` should be verified per model, because one community note suggests the opposite sense. Always pass it explicitly, since mflux may ignore an image without it.
- `reference_images[]`: maps to mflux edit/Redux/Kontext (up to 10 on Qwen-2.1); flatten alpha over white as mflux does.
- `reference_audio`: maps to mlx-audio `--ref_audio`; mlx-video `--audio-file`.
- `time_range` (start/end seconds): no runtime researched exposes it. Lift should trim the input with ffmpeg/PyAV before the run and splice the result back after. This is Lift-side, but it is a generic package operation, not model code.

### Gaps
- Exact mflux fill/Kontext flag names per model, and the sign convention of `--image-strength`, need confirming from `mflux-capabilities` output on a pinned version.
- I found no editing CLI documentation for sd-cli (`--init-img`/`--mask` exist in older versions but were not confirmed for 2026).
- I found no mlx-audio flags for speech-to-speech/enhancement, and no time-range or region-editing support in any audio or video runtime.
