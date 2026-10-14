# Mac-Runnable Open-Weight Video Generation Models as Lift Recipes (status as of Oct 2026)

**Scope (per coordinator):** only models with a working Apple Silicon path count as runnable. Any of these qualifies:
- the upstream repo on PyTorch MPS (shim stand-ins are fine)
- a community Mac port
- an MLX port
- stable-diffusion.cpp with Metal

fp8-only checkpoints fail on MPS, so each entry names a non-fp8 weight source. Models with no Mac path are listed in one line at the very end.

Research ran on 2026-10-11. Every claim has an inline source. Unverified items are in the Gaps sections.

---

## 1. Which current open-weight video models have a Mac path, and which version is current?

### Takeaway
The Mac-runnable frontier is:
- **LTX-2.3 / LTX-2.5** (Lightricks): MLX ports, Draw Things, PyTorch MPS (fragile)
- **Wan 2.1 / 2.2** (Alibaba): mlx-video, a PyTorch-MPS fork, Draw Things, GGUF
- **HunyuanVideo 1.5**: ComfyUI on MPS with frame-count limits
- **Smaller or older options:** Pyramid Flow (official MPS), FramePack (Mac fork), original HunyuanVideo (MLX port)
- **Non-diffusion tools:** LivePortrait, SadTalker, SeedVR2, RIFE

**Wan 2.2 is the newest open Wan.** Wan 2.5, 2.6, 2.7 and 3.0 are API-only, despite many SEO pages claiming otherwise.

### Cited Findings
- **Wan 2.5 never shipped open weights.** The last widely confirmed open Wan is Wan 2.2 (Apache 2.0) — [8frame](https://www.8frame.co/blog/is-wan-3-open-source); [kingy.ai](https://kingy.ai/blog/wan-3-0-analysis/)
- **Wan 2.7 has no official weights.** The Wan-AI HF org publishes weights only up to Wan 2.2, and there is no Wan-Video/Wan2.7 repo — [Runpod](https://www.runpod.io/articles/guides/wan-2-7-runpod); [Spheron](https://www.spheron.network/blog/deploy-wan-2-7-gpu-cloud-ai-video-generation/); [QuestStudio, Sep 2 2026](https://queststudio.io/blog/wan-2-7-open-source). LocalAIMaster calls the "Wan 2.7 download" sites SEO fabrications — [LocalAIMaster](https://localaimaster.com/blog/wan-2-7-open-source)
- **Wan 3.0: reports conflict.** Most sources say it is API-only. One says the AlibabaCloud-Official Wan3.0 repo had a README and license but no checkpoint as of Sep 1 2026 — [seedance.tv](https://www.seedance.tv/blog/wan-3-0-open-source-model); [wan27.org](https://wan27.org/blog/wan-3-open-source)
- **Official Wan2.2 releases:**
  - T2V-A14B, I2V-A14B, TI2V-5B (Jul 28 2025)
  - S2V-14B (Aug 26 2025)
  - Animate-14B (Sep 19 2025)
  - Nothing newer
  - Source: [Wan-Video/Wan2.2](https://github.com/Wan-Video/Wan2.2)
- **LTX-2.5 is the recommended version** in the Lightricks repo, and LTX-2.3 is "legacy" (its files are not interchangeable with 2.5). The repo has 9.7k stars — [Lightricks/LTX-2](https://github.com/Lightricks/LTX-2)
- **HunyuanVideo 1.5** (8.3B): released Nov 20 2025; last news Dec 23 2025 — [Tencent-Hunyuan/HunyuanVideo-1.5](https://github.com/Tencent-Hunyuan/HunyuanVideo-1.5)
- **Draw Things** shipped:
  - Wan 2.2 14B (v1.20250731.0)
  - Wan 2.2 5B import (1.20251014.0)
  - LTX-2 with audio (v1.20260228.0)
  - Wan 2.x High-Quality Preview (1.20260304.0)
  - Hunyuan video import only, in early 2025
  - Sources: [Draw Things on X](https://x.com/drawthingsapp/status/2028999832636145724); [DT wiki Wan 2.2](https://wiki.drawthings.ai/wiki/Wan_2.2); [downloads](https://drawthings.ai/downloads/)
- **Quality reputation:**
  - 2026 guides call Wan 2.2 the most practical Apache-2.0 local model, LTX-2.5 the 4K-with-audio option, and HunyuanVideo 1.5 the consumer-GPU option — [videogen.io](https://videogen.io/best-ai-video-models); [buildmvpfast Sep 2026](https://www.buildmvpfast.com/articles/best-llms-2026-guide/video-generation-ai)
  - TI2V-5B quality is disputed ("Wan 2.2 is a flop especially the 5B model") — [Wan2.2 #32](https://github.com/Wan-Video/Wan2.2/issues/32)
- **Stale but Mac-capable:**
  - Pyramid Flow: last news 2024-11-13 — [Pyramid-Flow](https://github.com/jy0205/Pyramid-Flow)
  - SadTalker: unmaintained since 2023, outputs 256/512 px — [sync.so](https://sync.so/blog/what-is-sadtalker)

### Inferences
- A Wan recipe should pin Wan 2.2 (or Wan 2.1 for VACE editing). For a non-developer audience, LTX-2.x and Wan 2.2 are the only frontier-quality options with a real Mac path.

### Gaps
- I could not load huggingface.co/Wan-AI directly to rule out a post-September Wan 3.0 release.
- The coordinator says **stable-diffusion.cpp with Metal supports Wan, LTX-2.3/2.5 and HunyuanVideo 1.5 as GGUF**. I did not verify this, its CLI flags, or its Mac timings this session.

---

## 2. Catalog: repo, CLI, license, size, non-fp8 weights, Mac path, editing

### Takeaway
Fastest and most reliable Mac paths:
- **MLX:** LTX-2.x via ltx-2-mlx or mlx-video; Wan via mlx-video
- **Official MPS:** LivePortrait, Pyramid Flow, SeedVR2 CLI

PyTorch-MPS runs of the official LTX, Wan or Hunyuan code work only partially and slowly.

### Cited Findings

| Model | Repo / CLI | License (code / weights); gated? | Size and memory | Non-fp8 weight source | Mac path and evidence | Editing |
|---|---|---|---|---|---|---|
| **LTX-2.5 / 2.3** | [Lightricks/LTX-2](https://github.com/Lightricks/LTX-2): `python -m ltx_pipelines.<distilled\|dfr_pipeline\|...>`. MLX: [dgrauet/ltx-2-mlx](https://github.com/dgrauet/ltx-2-mlx) CLI (`generate`, `retake`, `extend`, `keyframe`, `ic-lora`, `a2v`); [Blaizzy/mlx-video](https://github.com/Blaizzy/mlx-video) `mlx_video.ltx_2.generate` | Ports are MIT. Weights: LTX-2.x Community License, free under $10M annual revenue ([ltx.io](https://ltx.io/model/license); [HF commit](https://huggingface.co/Lightricks/LTX-2/commit/ec759a8a3363aa69b55ba802df86b0886157a71d)); HF terms must be accepted (gated) | About 22B DiT plus Gemma 12B text encoder; official quick-start ~66 GiB | ltx-2-mlx bf16/int8/int4 packs: 2.3 bf16 ~42 GB, q8 ~26 GB, q4 ~12 GB; 2.5 q8 ~75 GB. Official bf16 checkpoints (repo lists `fp8-cast` for bf16). GGUF via ComfyUI | **MLX (best):** 16 GB with `--low-ram`; 5 s 768×512 takes ~5–8 min on M3 Max; 16× faster than PyTorch MPS. **PyTorch MPS:** fp8 fails; two-stage gives NaN. **Draw Things:** LTX-2 | **Rich:** retake (time range), extend, keyframes, I2V anchors with strength, IC-LoRA control V2V (2.3), A2V, lip-dub (experimental) |
| **Wan 2.2 TI2V-5B** | [Wan2.2](https://github.com/Wan-Video/Wan2.2) `generate.py --task ti2v-5B`; Mac fork [HighDoping/Wan2.2-Mac](https://github.com/HighDoping/Wan2.2-Mac); MLX `mlx_video.wan_2.generate` | Apache 2.0; not gated | 5B; official ≥24 GB VRAM with offload; 1280×704 at 24 fps, ~5 s | Official Wan-AI/Wan2.2-TI2V-5B (bf16 via `--convert_model_dtype`); MLX conversion; GGUF T5 for the fork | **PyTorch MPS fork:** T2V 1h37m, I2V 47m on 32 GB M4 mini. **MLX:** supported, no timing. **Draw Things:** 5B | T2V + I2V (first frame) |
| **Wan 2.2 A14B T2V/I2V** | same; `--task t2v-A14B/i2v-A14B`; mlx-video | Apache 2.0 | 2×14B MoE; 80 GB official | GGUF Q4_K_S (8.75 GB per expert) + umt5 Q8 + wan_2.1_vae | **GGUF on M1 Max 64 GB:** 82 min for 2 s at 832×480 ([lilting.ch](https://lilting.ch/en/articles/ltx2-wan22-mac-local-video-gen)). MLX supported, untimed. Draw Things 14B | I2V; Lightning 4-step LoRA in mlx-video |
| **Wan 2.1 (1.3B/14B) + VACE** | Wan2.1; [ali-vilab/VACE](https://github.com/ali-vilab/VACE) `vace_wan_inference.py` | Apache 2.0 | 1.3B (480×832, 81 frames) / 14B (720p) | Official Wan-AI VACE weights | mlx-video runs Wan2.1 T2V. [lpalbou/mlx-gen](https://github.com/lpalbou/mlx-gen) lists a Wan2.1-VACE route. VACE on MPS is untested | **Best editing:** masked V2V inpaint/outpaint, ref-subject swap, pose/depth V2V. Inputs: `--src_video`, `--src_mask`, `--src_ref_images`, prompt |
| **HunyuanVideo 1.5** | [HunyuanVideo-1.5](https://github.com/Tencent-Hunyuan/HunyuanVideo-1.5) `torchrun generate.py` (Linux/CUDA only) | Tencent Hunyuan Community License (territory terms unverified) | 8.3B; 14 GB minimum with offload (CUDA); 480p/720p, 121 frames default | Official weights are not fp8 (FP8 GEMM is a runtime option); GGUF via sd.cpp per coordinator | **ComfyUI on M2 Ultra 64 GB:** OK at 73 frames; black output at 81–97; MPSGraph INT_MAX error at 121; suggested fix is tiled VAE ([ComfyUI #15109](https://github.com/Comfy-Org/ComfyUI/discussions/15109)) | I2V, SR upscaler |
| **HunyuanVideo (13B, original)** | MLX port [gaurav-nelson/HunyuanVideo_MLX](https://github.com/gaurav-nelson/HunyuanVideo_MLX) | Tencent community license | 13B; port needs 32 GB minimum | bf16 | M4 Max 3947 s per clip, M2 Ultra 2708 s ([X](https://x.com/ivanfioravanti/status/1870805883355271584)). M3 Max ~60 min for 73 frames at ~100 GB ([gist](https://gist.github.com/mdbecker/be0c1730e4a9a8830e46c72812f18a6e)) | — (superseded by 1.5) |
| **FramePack** | brandon929 Mac fork (Gradio) | see Gaps | 13B Hunyuan backbone | bf16 | M3 Ultra ~2.5 min per 1 s of video. M4 Max 64 GB ~19 min for 5 s at 416 res. Memory grows per run; noise at 720; F1 needs avg_pool3d fallback ([r/SD](https://pol1.lr.ggtyler.dev/r/StableDiffusion/comments/1k2neim/framepack_on_macos)) | Image → long video |
| **Pyramid Flow** | [jy0205/Pyramid-Flow](https://github.com/jy0205/Pyramid-Flow): notebook, Gradio `app.py` (no clean CLI) | MIT | <12 GB with CPU offload; 768p up to 10 s, 384p up to 5 s | official (miniFLUX/SD3) | **Official MPS backend** (PR #113); example M2 MBP 24 GB | T2V, I2V |
| **LivePortrait** | [KwaiVGI/LivePortrait](https://github.com/KwaiVGI/LivePortrait) `inference.py -s <src> -d <driving>` | see Gaps | small | official | **Official macOS:** `requirements_macOS.txt` + `PYTORCH_ENABLE_MPS_FALLBACK=1`, ~20× slower than a 4090. Animals mode (X-Pose) is unsupported | Portrait V2V editing; motion transfer from a driving video or `.pkl` |
| **SadTalker** | [OpenTalker/SadTalker](https://github.com/OpenTalker/SadTalker) | see Gaps | small | official | Install doc tested on M1 / macOS 13.3 ([install.md](https://github.com/OpenTalker/SadTalker/blob/main/docs/install.md)). Dated quality | Image + audio → talking head |
| **SeedVR2** (upscale/restore) | Standalone `inference_cli.py` in [numz/ComfyUI-SeedVR2_VideoUpscaler](https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler) | Code Apache 2.0; weights license unconfirmed | 3B / 7B; FP16 needs 24 GB+; GGUF Q4 runs in 8 GB | **FP16 or GGUF Q4_K_M/Q8_0** (the CLI default is 3B FP8, so override `--dit_model`) | **"Full MPS support."** BlockSwap is off on Mac. MPS fixes through v2.5.24 (2025-12-24) | Video upscale (source video in) |
| **RIFE** (interpolation) | Practical-RIFE | see Gaps | tiny | official | ComfyUI RIFE on M2 Max hit "MPS: Unsupported Border padding mode"; CPU fallback likely needed ([PyTorch forum](https://discuss.pytorch.org/t/rife-vfi-error-on-comfyui-on-mac/194087)) | Frame interpolation |

### Inferences
- The `--dit_model` default in SeedVR2 is FP8. A Lift recipe must explicitly select an FP16 or GGUF model. The same applies to LTX (avoid `ltx-2-19b-dev-fp8`) and to Wan/Hunyuan fp8 repacks on HF.

### Gaps
- No Mac timing found for mlx-video Wan2.2-5B or A14B, VACE, or SeedVR2.
- Licenses not verified this session: LivePortrait (weights reportedly rely on non-commercial InsightFace models), SadTalker, FramePack, RIFE, SeedVR2 weights.
- **Plausible but no Mac evidence found:**
  - Kandinsky 5.0 Lite 2B (MIT; `test.py`; `--offload`) — [HF card](https://huggingface.co/kandinskylab/Kandinsky-5.0-T2V-Lite-sft-5s)
  - SkyReels V2 DF-1.3B (14.7 GB peak; Wan-based) — [HF](https://huggingface.co/Skywork/SkyReels-V2-DF-1.3B-540P)
  - Lucy Edit Dev (5B, Wan2.2-5B arch, instruction V2V editing, non-commercial, Diffusers `LucyEditPipeline` only) — [HF](https://huggingface.co/decart-ai/Lucy-Edit-Dev)
  - LatentSync 1.5/1.6 (8/18 GB VRAM; one M4 mini user said it did not work) — [repo](https://github.com/bytedance/LatentSync); [Comfy forum](https://forum.comfy.org/t/lip-sync-workflow-for-mac-apple-silicon/3919)
  - CogVideoX 1.5, Mochi 1, Allegro, SVD, Hallo3, Sonic, OmniAvatar and FILM were not checked.

---

## 3. Mac blockers, required workarounds and wall-clock times

### Takeaway
PyTorch MPS runs of big video DiTs hit three recurring blockers:
- fp8 dtypes are missing
- the 2^32-element tensor limit causes INT_MAX errors and black frames on long clips
- multi-stage samplers produce NaN

MLX ports avoid most of this and run about 3.5–16× faster. Realistic times:
- LTX on MLX: ~1–8 min per clip (M3 Max)
- Wan 5B on PyTorch MPS: 45–100 min
- Wan 14B GGUF: 80+ min for 2 s

### Cited Findings
- **MPS has no fp8.** On M1 Max, the LTX-2 fp8 checkpoint and the Gemma fp4_mixed encoder fail with `Undefined type Float8_e4m3fn`. Wan fp8 also errors; GGUF works — [lilting.ch](https://lilting.ch/en/articles/ltx2-wan22-mac-local-video-gen)
- **LTX-2 via ComfyUI on MPS:** two-stage gives NaN/Inf at VAE decode. Single-stage distilled GGUF took ~3 min for 33 frames at 768×512 but was nearly static. M3 reports ~5 min and M1 16 GB ~15 min for a few seconds — [lilting.ch](https://lilting.ch/en/articles/ltx2-wan22-mac-local-video-gen)
- **LTX-2.5 on MLX:**
  - 53 s vs 853 s for PyTorch MPS on M3 Max 64 GB
  - 1.4 s clip in ~1 min; 5 s at 768×512 in ~5–8 min
  - 32 GB recommended; 24 GB with `--low-ram`
  - macOS 26 watchdog stall (25–130× slower) is fixed by `AGX_RELAX_CDM_CTXSTORE_TIMEOUT=1`
  - Source: [gist](https://gist.github.com/DanielHauschildt/9ad1d7cef482ed508a121881280b74dd/)
- **ltx-2-mlx:** q8 fits 16 GB with `--low-ram` (streams from disk); bf16 fits 32 GB. On M1 Max, 576×1024×241 distilled I2V took 701 s, or 563 s with `LTX2_COMPUTE_DTYPE=float16`. Install via `uv sync --all-extras` — [dgrauet/ltx-2-mlx](https://github.com/dgrauet/ltx-2-mlx)
- **janishar/ltx-2-mlx:** 39.9 s (MLX int8) vs 142.0 s (MPS bf16); ~40 s for 2 s at 704×448; 5 s at 1280×704 took 207.5 s and swapped on 64 GB — [janishar/ltx-2-mlx](https://github.com/janishar/ltx-2-mlx)
- **mlx-video:** MIT; LTX-2 plus Wan2.1/2.2; Python 3.11+, MLX ≥0.22; PyTorch only for weight conversion; no published timings — [Blaizzy/mlx-video](https://github.com/Blaizzy/mlx-video)
- **Wan2.2-Mac fork:**
  - Flags: `PYTORCH_ENABLE_MPS_FALLBACK=1`, `--device mps --offload_model True --convert_model_dtype --t5_quant` (needs llama.cpp from brew)
  - Limits: TI2V-5B only; VAE2.2 tiling broken; WIP
  - Source: [HighDoping/Wan2.2-Mac](https://github.com/HighDoping/Wan2.2-Mac)
- **Wan 2.2 14B GGUF on M1 Max:** ~250 s/step; wan2.2_vae failed with a channel mismatch and wan_2.1_vae worked — [lilting.ch](https://lilting.ch/en/articles/ltx2-wan22-mac-local-video-gen)
- **Diffusers MPS limits:** no tensors over 2^32 elements; batching unreliable — [Diffusers MPS](https://huggingface.co/docs/diffusers/optimization/mps)
- **CUDA extras in upstream requirements** (the shim must cover these):
  - Wan2.2 lists flash_attn — [Wan2.2](https://github.com/Wan-Video/Wan2.2)
  - LTX-2's `natten` extra is skipped on macOS (falls back to Triton or eager attention); fp8-scaled-mm needs Hopper — [LTX-2](https://github.com/Lightricks/LTX-2)
  - HunyuanVideo 1.5 has optional flash-attn, SageAttention, flex-block-attn and sgl-kernel — [HunyuanVideo-1.5](https://github.com/Tencent-Hunyuan/HunyuanVideo-1.5)

### Inferences
- Recipe environment defaults: `PYTORCH_ENABLE_MPS_FALLBACK=1` for PyTorch recipes; `AGX_RELAX_CDM_CTXSTORE_TIMEOUT=1` for MLX recipes on macOS 26.
- Memory tiers for the UI:
  - 16 GB: LTX q8/q4 with `--low-ram` (slow), LivePortrait, SeedVR2 GGUF, Wan 1.3B
  - 32 GB: LTX bf16/int8, Wan2.2-5B
  - 64 GB+: Wan 14B (still very slow)
- The two best recipes are MLX Python repos, not PyTorch MPS. Lift's recipe format would need an "MLX instead of PyTorch" install variant. Staying PyTorch-only leaves LivePortrait, SeedVR2, Pyramid Flow and the slow Wan2.2-5B fork.

### Gaps
- No verified sd.cpp Metal timings for Wan, LTX or Hunyuan 1.5.
- No end-to-end 16 GB M1 report for any model beyond the LTX "~15 min" anecdote.
- Whether official HunyuanVideo 1.5 `generate.py` runs on MPS with a shim is untested.

---

## 4. Editing support in Mac-runnable models

### Takeaway
On a Mac, the editing modes with a working path are:
- **LTX-2.x via ltx-2-mlx:** retake a time range, extend, keyframe interpolation, IC-LoRA control V2V on 2.3, A2V, lip-dub (experimental)
- **LivePortrait:** portrait V2V and motion transfer
- **SeedVR2:** upscale and restore
- **RIFE:** interpolation, with CPU fallback

**Wan2.1-VACE** (masked inpaint/outpaint, reference swap) is the most complete editor, but its Mac path is unverified.

### Cited Findings
- **ltx-2-mlx editing inputs:**
  - `retake`: source video + `--start/--end` (latent frames)
  - `extend`: source video + `--extend-frames`
  - `keyframe`: reference images
  - `ic-lora`: reference video (depth/pose/edges) + LoRA weight
  - `--image PATH FRAME STRENGTH`: repeatable anchors
  - `a2v`, `lipdub` (experimental)
  - On 2.5, ic-lora and lipdub are unavailable (no official 2.5 task IC-LoRAs)
  - Source: [dgrauet/ltx-2-mlx](https://github.com/dgrauet/ltx-2-mlx)
- **Official LTX-2 pipelines:** Retake, ICLora, KeyframeInterpolation, A2Vid, DubIt, HDR IC-LoRA — [Lightricks/LTX-2](https://github.com/Lightricks/LTX-2); [LTX docs](https://docs.ltx.io/open-source-model/integration-tools/pytorch-api)
- **VACE:**
  - Tasks: R2V, V2V, MV2V; Move/Swap/Reference/Expand/Animate-Anything
  - CLI inputs: `--src_video`, `--src_mask`, `--src_ref_images`, `--prompt`
  - `vace_pipeline.py` adds preprocessing (`--task --mode --bbox --video`)
  - Source: [ali-vilab/VACE](https://github.com/ali-vilab/VACE)
- **mlx-video** I2V for Wan2.2 I2V-14B via `--image` — [Blaizzy/mlx-video](https://github.com/Blaizzy/mlx-video)
- **LivePortrait** has supported "portrait video editing (aka v2v)" since 2024-07-19 — [LivePortrait](https://github.com/KwaiVGI/LivePortrait)
- **SeedVR2 CLI flags:** `--resolution`, `--batch_size` (4n+1), `--chunk_size`, `--temporal_overlap`, `--color_correction`, `--vae_encode_tiled/--vae_decode_tiled` — [numz SeedVR2](https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler)
- **HunyuanVideo 1.5 CLI** has only I2V (`--image_path`) and SR (`--sr`), with no V2V editing — [HunyuanVideo-1.5](https://github.com/Tencent-Hunyuan/HunyuanVideo-1.5)

### Inferences
Lift editing-UI schemas:
- **Retake:** video, start, end, prompt
- **Extend:** video, length, prompt
- **Keyframes:** images, each with frame index and strength
- **Control V2V:** reference video, type, strength, prompt
- **Masked inpaint** (VACE): video, mask video, ref images, prompt
- **Portrait V2V:** source video, driving video
- **Upscale:** video, target resolution

The ltx-2-mlx time ranges are in latent frames, so Lift must convert from seconds.

### Gaps
- Whether the official LTX Retake CLI takes seconds or frames was not verified.
- VACE on MPS or through mlx-gen is unverified.
- No Mac-verified instruction-based video editor was found. Lucy Edit Dev is the candidate, but it is non-commercial and has no Mac evidence.

---

## 5. Ranked shortlist of recipe candidates

### Takeaway
1. **LTX-2.3/2.5 via ltx-2-mlx.** Fastest Mac path; T2V, I2V and audio; full editing (retake, extend, keyframe); fits 16 GB with `--low-ram`; commercial use free under $10M revenue (gated).
2. **Wan2.2 TI2V-5B (and I2V-14B) via mlx-video.** Apache 2.0, ungated. **This is the image-input chain:** an image from Lift or the user feeds I2V, then SeedVR2 upscales. The HighDoping PyTorch-MPS fork is the slow fallback (47 min for I2V).
3. **LivePortrait.** Official macOS support. A portrait image or video plus a driving video gives an animated or edited portrait. Small model, quick to ship. The weights license still needs checking.
4. **SeedVR2 standalone CLI.** MPS-supported video upscaling and restoration, in FP16 or GGUF, as the post-process for every other recipe.
5. **Alternate: Pyramid Flow** (official MPS, MIT, but 2024-era quality), or **Wan2.1-VACE-1.3B** for masked editing once its Mac path is tested.

### Cited Findings
- **LTX (MLX):** [dgrauet/ltx-2-mlx](https://github.com/dgrauet/ltx-2-mlx); [gist timings](https://gist.github.com/DanielHauschildt/9ad1d7cef482ed508a121881280b74dd/); [ltx.io license](https://ltx.io/model/license)
- **Wan (MLX):** [Blaizzy/mlx-video](https://github.com/Blaizzy/mlx-video); [Wan2.2 license](https://github.com/Wan-Video/Wan2.2); [HighDoping/Wan2.2-Mac](https://github.com/HighDoping/Wan2.2-Mac)
- **LivePortrait:** [KwaiVGI/LivePortrait](https://github.com/KwaiVGI/LivePortrait)
- **SeedVR2:** [numz/ComfyUI-SeedVR2_VideoUpscaler](https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler)
- **Pyramid Flow:** [jy0205/Pyramid-Flow](https://github.com/jy0205/Pyramid-Flow); **VACE:** [ali-vilab/VACE](https://github.com/ali-vilab/VACE)

### Inferences
- **Possible 3D tie-in:** render a turntable from an image-to-3D mesh, then use it as an LTX IC-LoRA (2.3) control video for restyling.

### Gaps
- Benchmark mlx-video Wan2.2-5B I2V locally before committing.
- Verify the LivePortrait/InsightFace and SeedVR2 weight licenses.
- Decide whether the Lift recipe format accepts MLX repos. This is an internal question.

### Excluded (no Mac path)
Step-Video-T2V/TI2V (30B, 80 GB, sm_80+ kernels), MAGI-1/1.1 (24B on 8×H100; CUDA env), Open-Sora 2.0 (52–60 GB peak on H100; xformers, flash-attn, ColossalAI), MiniMax H3 (30–33B; license bans local use in US/EU/UK/KR), Wan2.2 S2V-14B / Animate-14B (80 GB; not in Mac ports), InfiniteTalk/MultiTalk (Wan 14B; pinned xformers, flash_attn, cu121), LongCat-Video and its Avatar (13.6B; flash-attn and cu124 pins; no Mac reports). Sources: [Step-Video](https://github.com/stepfun-ai/Step-Video-T2V), [MAGI-1](https://github.com/SandAI-org/MAGI-1), [Open-Sora](https://github.com/hpcaitech/Open-Sora), [MiniMax H3](https://explainx.ai/blog/minimax-h3-open-video-model-hailuo-july-2026), [Wan2.2](https://github.com/Wan-Video/Wan2.2), [InfiniteTalk](https://github.com/MeiGen-AI/InfiniteTalk), [LongCat-Video](https://github.com/meituan-longcat/LongCat-Video).
