# Image Editing, Image-to-Image and Image Utility Models as Lift Recipes — Mac-runnable only (state as of Oct 2026)

Scope: only models with a Mac (Apple Silicon) path. A path counts if it is upstream PyTorch MPS (shim stand-ins allowed), a community Mac port, an MLX port such as mflux, or stable-diffusion.cpp with Metal. Each entry names its path and the evidence for it.
Labels: **S** = stated by the cited source; **inf.** = my inference. Memory figures marked inf. are parameters × 2 bytes (bf16) and are not measured.
Tiers: **A = Mac path confirmed by a source**. **B = no blocker found and pure PyTorch, but no source shows it running on a Mac** (it needs a smoke test before it can be called runnable). Models with no Mac path, or with no evidence and with blockers, are listed in one line at the end.

## 1. Mac-runnable catalog: repo, runnable path, license, size, and edit inputs

### Takeaway
Instruction editors with a confirmed Mac path:
- **Qwen-Image-Edit-2511**: Apache-2.0. Two Mac paths: the MPS-first CLI `qwen-image-mps`, and mflux. Needs 64 GB+.
- **FLUX.2 [klein] 4B**: Apache-2.0, ~8 GB, through mflux. The editor for 16–32 GB Macs.
- **FLUX.1 Kontext [dev]**: non-commercial and gated, through mflux.
- **Qwen-Image-2.1**: research license, through mflux.

Utilities with a confirmed Mac path:
- **SeedVR2**: upscaling. Apache-2.0, through the numz CLI with MPS fixes, or mflux.
- **FLUX Fill**: inpaint and outpaint, through mflux.
- **DreamO**: identity and subject reference, with explicit MPS support but Gradio only.

Background removal (BiRefNet, BEN2) and multiview (MV-Adapter, Zero123++) look easy to run on a Mac but are tier B. I found no source showing them running on MPS.

### Cited Findings

**Catalog table** (sources are in the bullets below)

| Tier | Model | Runnable Mac path (evidence) | Lift-style CLI? | License (code / weights) | Gated | Size / memory | Edit inputs (what the editing UI needs) |
|---|---|---|---|---|---|---|---|
| A | **Qwen-Image-Edit-2511** (Dec 2025) | (1) `qwen-image-mps edit` on PyTorch MPS. (2) mflux "Qwen Image … editing" (MLX). Mac timings exist (see below) | Yes: qwen-image-mps `edit -i … -p … -s/-f/-uf --seed --cfg-scale --aspect --lora -o` (MIT) | Apache-2.0 / Apache-2.0 | No | 20B; ~54 GB download; used most of 64 GB RAM | **Instruction edit**: 1+ source images (1–3 is optimal per the 2509 card) and a text instruction. Settings: steps (50, or 8/4 with the Lightning LoRA), cfg (example true_cfg 4.0), seed, aspect (no free size). 2509 also takes ControlNet-style maps (depth, edge, keypoint) as image inputs. **No mask mode** documented. Multi-turn: 2511 claims "reduced image drift". Built-in relight and new-viewpoint LoRA effects |
| A | **Qwen-Image-2.1** (+Turbo) (Sep 20 / Oct 9 2026) | mflux lists "Qwen Image 2.1 … multi-reference editing, LoRA, RGBA, ControlNet Union", with `--compute-precision float16` for M1 | mflux CLI; upstream offers only diffusers, SGLang and vLLM | Qwen Research License | Not stated | 7B DiT + 8B text encoder (~30 GB bf16, inf.); Turbo uses 8 steps | **Multi-reference**: up to 10 reference images. **Local edit**: circles, painted annotations or a separate mask (format not documented). **RGBA** output, including transparent-layer edits and subject extraction |
| A | **FLUX.2 [klein] 4B** (Jan 15 2026) | mflux "FLUX.2 (Jan 2026, 4B & 9B) … Text-to-image, editing"; a guide shows `mflux-generate-flux2 --model flux2-klein-4b` | mflux CLI; official `scripts/cli.py` is interactive and CUDA-tested | Apache-2.0 (4B); 9B is Non-Commercial | Not stated | 4B, ~8 GB VRAM | **Instruction edit** and **multi-reference composition** (single and multiple references; limit undocumented). Distilled 4-step |
| A | **FLUX.1 Kontext [dev]** | mflux "FLUX.1 … Kontext editing" | mflux CLI; official `python -m flux kontext --prompt` (CUDA path) | Apache-2.0 code / FLUX.1-dev Non-Commercial weights (outputs are commercially usable) | Yes | 12B (~24 GB + T5, inf.) | **Instruction edit**: one image plus text, guidance 2.5. Character, style and object reference. **Multi-turn**: "minimal visual drift" across successive edits (S). Diffusers also has Kontext-Inpaint (image + mask + `strength`) |
| A | **FLUX.1 Fill [dev]** | The mflux feature list includes fill/inpainting, and the coordinator confirms that mflux handles Fill (not mapped per model on the README) | mflux CLI | FLUX.1-dev Non-Commercial | Yes | 12B | **Inpaint**: image + mask + prompt (white = repaint is the diffusers inpaint convention). **Outpaint**: expanded canvas + mask over the new area |
| A | **SeedVR2 3B/7B** (Jun 2025) | (1) numz `inference_cli.py` on MPS. Its changelog has MPS device fixes, a CPU fallback for bicubic+antialias, in-process execution on Mac to avoid MPS allocator failures, and an MPS leak fix in v2.5.24 (2025-12-24). (2) `mflux-upscale-seedvr2`, plus MLX int8 7B weights | Yes: `python inference_cli.py image.jpg --resolution 1080 --max_resolution --dit_model …` | Apache-2.0 | No | 3B/7B in FP16, FP8 or GGUF; 8 GB with Q4 GGUF | **Upscale**: image plus target short side (`--resolution`, default 1080) or a 2× factor (mflux); max edge; model size. Alpha is preserved |
| A | **DreamO v1.1** (Jun 2025) | The README says macOS Apple Silicon is supported via MPS, auto-detected or `--device mps` | No: Gradio `app.py` only | License not stated; FLUX base (NC, inf.) | Base gated | 24 GB; 6.5 GB with nunchaku + offload | **Multi-reference composition** by task: IP (object/character), ID (face), Try-On (garments), Style, multi-condition. Each reference gets a task tag, plus a prompt |
| A (weak) | **UNO** (Apr 2025) | The README tells "macOS MPS" users to install the correct torch first (an implicit claim of support) | Yes: `inference.py --prompt --image_paths --width --height` | Apache-2.0 code; FLUX.1-dev NC base | Base gated | ~16 GB (fp8 + offload) | **Subject reference**: 1+ reference images, prompt, output W×H. Superseded by USO/UMO |
| A (binary) | **Real-ESRGAN** | Portable NCNN-Vulkan executable for macOS (no PyTorch). The Python path on MPS is unverified | NCNN binary CLI (no `outscale`); Python `inference_realesrgan.py -n -i -o -s --tile --face_enhance --fp32` | LICENSE file (type not on page) | No | Small | **Upscale**: image, factor, tile, model (x4plus / anime_6B / general-x4v3) |
| B | **BiRefNet** (HR / dynamic / matting / lite-2K) | No CUDA-only deps listed; standard HF `AutoModelForImageSegmentation`; Swin attention uses PyTorch SDPA since 2025-09. No Mac source found | Yes: `inference.py` | MIT code | No | 4.8 GB FP32 / 3.5 GB FP16 | **Background removal**: image only, outputs an alpha matte. Choice of resolution variant |
| B | **BEN2** | Sample code falls back to CUDA or CPU; MPS is not mentioned | Python API (`pip ben2`) | MIT | No | 94.6M | Image → cut-out; `refine_foreground` toggle |
| B | **MV-Adapter** (ICCV 2025) | Pure diffusers SDXL. Install docs use cu118; CV-CUDA is needed only for texturing. No Mac source | Yes: `python -m scripts.inference_i2mv_sdxl --image --text --output --remove_bg --seed --num_inference_steps` | Apache-2.0 | No | ~14 GB | **Multi-view**: one image (+ optional text) → 6 views; built-in background removal |
| B | **Zero123++ v1.2** | Diffusers custom pipeline at ~5 GB; no Mac source | Python snippet | Apache-2.0 code / CC-BY-NC weights | No | ~5 GB | Square image ≥320 px → 6 fixed views on a gray background |
| B | **SAM 2.1** | Conflicting: issue #122 claims MPS support, but #687 reports an MPS placeholder-storage failure on an M4 | API / notebooks | Apache-2.0 | No | 39M–224M | Point/box prompts or automatic masks |

**Evidence for tier A**
- qwen-image-mps (MIT) "Qwen Image models through MPS". Device order is MPS, then CUDA, then CPU. Uses Edit-2511 via `QwenImageEditPlusPipeline`; MPS runs bf16 with the generator on CPU for stability. `edit` takes `-i/--input` (several images blend), `-s` (default 50), `-f` (8-step), `-uf` (4-step), `--seed`, `--cfg-scale`, `--lora`, `--anime`. No inpaint or outpaint — [GitHub qwen-image-mps](https://github.com/ivanfioravanti/qwen-image-mps)
- Mac timings (Qwen-Image via qwen-image-mps): 50 steps took 49 min on an M4 Max 128 GB, against 42 s per image on an M3 Ultra. Qwen-Image-Edit is a 54 GB download that used most of 64 GB RAM ("a larger machine is almost required") — [Simon Willison](https://simonwillison.net/2025/Aug/19/qwen-image-edit/)
- On an M1 Max, Qwen-Image-Edit in ComfyUI went from ~80 s to ~10 min because of bf16. M1, M2 and M3 lack hardware bf16, which starts with M4 — [lilting.ch](https://lilting.ch/en/articles/comfyui-qwen-mps-bf16-slowdown)
- mflux (MIT, MLX) supports FLUX.2 4B/9B (T2I + editing), Qwen Image 20B (editing), Qwen Image 2.1 (multi-reference editing, RGBA, ControlNet Union), FLUX.1 (Kontext editing, Canny ControlNet, ControlNet upscaling), SeedVR2 (upscaling), Depth Pro, FIBO (editing), and Z-Image. Its feature list includes fill/inpainting, Redux and depth conditioning. Quantization uses `-q 8`, and `--compute-precision float16` is available for M1. It calls Qwen Image "large and slower" and FLUX.2 the "fastest and smallest" — [GitHub mflux](https://github.com/filipstrand/mflux)
- klein 4B runs on a Mac with quantized MLX through mflux (`mflux-generate-flux2 --model flux2-klein-4b`) — [itnext guide](https://itnext.io/generate-images-free-locally-on-your-mac-with-ai-312382bc7754)
- `mflux-upscale-seedvr2 --model seedvr2-7b --image-path input.png --resolution 2x` is tiled by default — [HF benc0/SeedVR2-7B-mlx-int8](https://huggingface.co/benc0/SeedVR2-7B-mlx-int8); [mflux v0.14.0 release](https://newreleases.io/project/github/filipstrand/mflux/release/v.0.14.0)
- numz SeedVR2 CLI: single-image input, RGBA preserved, `--resolution`, `--max_resolution`, `--batch_size` (4n+1), `--dit_model`, VAE tiling. On macOS BlockSwap is auto-disabled and processing runs in-process to avoid MPS allocator failures. v2.5.24 (2025-12-24) restored MPS cache clearing. Apache-2.0 — [numz README](https://raw.githubusercontent.com/numz/ComfyUI-SeedVR2_VideoUpscaler/main/README.md); MPS device enumeration fix ("mps" instead of "mps:0") and bicubic/antialias CPU fallback for torch <2.8 — [numz GitHub](https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler)
- DreamO: "macOS with Apple Silicon is supported through MPS", auto-detected or `--device mps`. `--quant none|int8|nunchaku`, `--offload`. Tasks are IP, ID, Try-On, Style and multi-condition. v1.1 released 2025-06-24 — [DreamO README](https://raw.githubusercontent.com/bytedance/DreamO/main/README.md)
- UNO: users on "macOS MPS" are told to install the correct torch first. `inference.py --prompt --image_paths --width --height`. ~16 GB with fp8 + offload. Successors USO (2025-08-29) and UMO (2025-09-12) — [UNO README](https://raw.githubusercontent.com/bytedance/UNO/main/README.md)
- Real-ESRGAN: a portable NCNN executable exists for macOS, needs no CUDA or PyTorch, and lacks `outscale` — [Real-ESRGAN README](https://raw.githubusercontent.com/xinntao/Real-ESRGAN/master/README.md)

**Model facts for tier A**
- Edit-2511: Apache-2.0. Compared with 2509: reduced drift, multi-person consistency, built-in community LoRAs (lighting, new viewpoints), industrial and material edits, geometric construction lines. Example uses 40 steps and true_cfg 4.0; 20B BF16 — [HF Qwen-Image-Edit-2511](https://huggingface.co/Qwen/Qwen-Image-Edit-2511)
- Edit-2509: 1–3 input images is optimal; native ControlNet inputs (depth, edge, keypoint); text, font and material editing — [HF Qwen-Image-Edit-2509](https://huggingface.co/Qwen/Qwen-Image-Edit-2509). Release dates: Edit Aug 25 2025, 2509 Sep 22 2025, 2511 Dec 23 2025; Qwen-Image-Layered (20B) Dec 19 2025 — [HF Qwen org listing](https://huggingface.co/models?author=Qwen&search=Qwen-Image&sort=created)
- Qwen-Image-2.1: 2026-09-20, Turbo 2026-10-09, Qwen Research License. Up to 10 references; circles, annotations or masks; RGBA, transparent layers and subject extraction. PE-I2I/PE-T2I are 9B prompt rewriters. No VRAM figures and no Mac mention upstream — [Qwen-Image-2.1 README](https://raw.githubusercontent.com/QwenLM/Qwen-Image-2.1/main/README.md); [HF Qwen-Image-2.1](https://huggingface.co/Qwen/Qwen-Image-2.1)
- FLUX.2: [klein] 4B and 4B Base are Apache-2.0; the 9B variants are Non-Commercial; [dev] 32B is Non-Commercial (25.11.2025). All do T2I plus single- and multi-reference editing. klein 4B needs ~8 GB. The official code was tested on GB200/CUDA 12.9 — [flux2 README](https://raw.githubusercontent.com/black-forest-labs/flux2/main/README.md)
- Kontext [dev]: 12B, gated, FLUX.1-dev Non-Commercial (outputs may be used commercially), guidance 2.5, iterative editing with "minimal visual drift" — [HF FLUX.1-Kontext-dev](https://huggingface.co/black-forest-labs/FLUX.1-Kontext-dev). Official repo: `python -m flux kontext --prompt` / `--loop`; Apache code; Fill is listed for "In/Out-painting" — [GitHub flux](https://github.com/black-forest-labs/flux)
- Diffusers: "White pixels in the mask are repainted while black pixels are preserved" (FluxInpaintPipeline). `FluxKontextInpaintPipeline` takes `mask_image` and `strength`. Fill "supports both inpainting and outpainting" — [Diffusers Flux docs](https://huggingface.co/docs/diffusers/main/en/api/pipelines/flux)
- SeedVR2 official repo: Apache-2.0, video-only torchrun script, flash_attn + apex, H100-class GPU; ICLR 2026. This is the non-Mac path; use numz or mflux instead — [GitHub SeedVR](https://github.com/ByteDance-Seed/SeedVR)

**Facts for tier B**
- BiRefNet: MIT code. Variants include HR (2048), HR-matting, dynamic (256–2304) and lite-2K. `inference.py`. 4.8 GB FP32 / 3.5 GB FP16. SDPA attention since 2025-09-23. No CUDA-only deps listed. No Mac mention — [GitHub BiRefNet](https://github.com/ZhengPeng7/BiRefNet). A ComfyUI user says a BEN2/BiRefNet workflow "runs well on … my Apple laptop" but does not say whether MPS was used — [Medium](https://medium.com/code-canvas/background-removal-in-comfyui-just-got-really-really-good-2a12717ff0db)
- RMBG-2.0 is the same architecture under CC BY-NC 4.0 and gated, so BiRefNet is preferable — [HF RMBG-2.0](https://huggingface.co/briaai/RMBG-2.0)
- BEN2: MIT, 94.6M, `BEN_Base.inference(image, refine_foreground)`, CUDA-else-CPU sample — [HF BEN2](https://huggingface.co/PramaLLC/BEN2)
- MV-Adapter: Apache-2.0, i2mv/t2mv/ig2mv scripts, ~14 GB, 6 views, cu118 install, CV-CUDA only for texturing — [GitHub MV-Adapter](https://github.com/huanngzh/MV-Adapter)
- Zero123++: Apache code, CC-BY-NC 4.0 weights; 6 views at azimuths 30–330°, v1.2 elevations 20/−10; ~5 GB; gray background, so use rembg after — [zero123plus README](https://raw.githubusercontent.com/SUDO-AI-3D/zero123plus/main/README.md)
- SAM 2.1: Apache-2.0, 38.9M–224.4M, optional CUDA extension — [SAM 2 README](https://raw.githubusercontent.com/facebookresearch/sam2/main/README.md); MPS failure on an M4 despite #122 claiming support — [sam2 issue #687](https://github.com/facebookresearch/sam2/issues/687)

### Inferences
- **What the editing UI needs**, across the Mac-runnable set:
  - **Instruction edit** (Qwen-Edit, FLUX.2, Kontext, Qwen-2.1): source image, instruction, and 0–N extra references. Max references: Qwen-Edit 3 (optimal), Qwen-2.1 10, Kontext 1, FLUX.2 unknown.
  - **Mask inpaint** (FLUX Fill, Kontext-Inpaint, Qwen-2.1): image plus a binary mask, assuming white = edit.
  - **Outpaint** (FLUX Fill only): canvas expand plus a mask over the new region.
  - **Multi-reference composition with task tags** (DreamO).
  - **Upscale**: target short side for SeedVR2, or a factor for SeedVR2 via mflux and for Real-ESRGAN.
  - **Relight**: none of the Mac-confirmed models has a dedicated relight mode. Qwen-2511's built-in lighting LoRA is invoked by instruction.
  - **Img2img strength**: only Kontext-Inpaint `strength` exposes it.
  - **Multi-turn**: documented only for Kontext (minimal drift) and Qwen-2511 (reduced drift). Treat feeding outputs back in as untested for the rest.
- **Two runtime families.** qwen-image-mps and numz SeedVR2 are PyTorch-MPS repos with real CLIs, which matches Lift's current uv + PyTorch model directly. mflux is a single MLX package (MIT) that covers Kontext, Fill, FLUX.2, Qwen-Edit, Qwen-2.1 and SeedVR2. One mflux-based recipe family could cover most editing modes, but it brings in MLX instead of PyTorch.
- **Memory tiers (inf.):** Qwen-Image-Edit (~54 GB) needs a 64 GB+ Mac and is very slow on M1–M3 because of bf16. Kontext and Fill (~34 GB bf16) fit 48 GB+, or less with mflux `-q 8`. FLUX.2 klein 4B (~8 GB), SeedVR2 GGUF (~8 GB) and BiRefNet (~4 GB) fit 16 GB Macs.
- **Licensing among Mac-runnable models:**
  - Apache or MIT: Qwen-Edit-2511, FLUX.2 klein 4B, SeedVR2, BiRefNet, BEN2, MV-Adapter, SAM 2.1.
  - Non-commercial or gated: Kontext, Fill, FLUX.2 9B, Zero123++ weights, and DreamO/UNO via their FLUX-dev base.
  - Research license: Qwen-2.1.

### Gaps
- Tier B (BiRefNet, BEN2, MV-Adapter, Zero123++, SAM 2.1) has no source showing MPS working. Each needs a smoke test before it can be called runnable.
- No M-series timings for Qwen-Image-Edit-2511 specifically, nor for Qwen-2.1, FLUX.2 klein, Kontext via mflux, or SeedVR2.
- mflux: which CLI flags expose Fill, multi-reference FLUX.2 editing, and Qwen-2.1 masks is not confirmed (the README maps features to per-model docs I did not read). The README shows no release version or date.
- Qwen-Image-2.1's mask format and the commercial terms of the Qwen Research License are undocumented. FLUX.2's reference limit and whether it is gated are undocumented.
- Unverified Mac candidates I did not research and that may have paths: OmniGen2 and LongCat-Image-Edit (diffusers, flash-attn optional); AuraSR (pip, 0.6B); GFPGAN/CodeFormer (BasicSR, which from prior knowledge may break on newer torchvision); IC-Light (SD1.5, Gradio-only); IP-Adapter; stable-diffusion.cpp Metal coverage for any of these editors.

## 2. Which Mac-runnable models chain naturally with Lift's image-to-3D recipes (TRELLIS.2, Pixal3D, UniRig)?

### Takeaway
A Mac-confirmed chain exists for editing and upscaling. Background removal, the most direct feeder, still depends on a tier-B model (BiRefNet/BEN2) until it is smoke-tested. Qwen-Image-2.1 via mflux, with RGBA subject extraction, could fill that role, but only under a research license.

### Cited Findings
- Qwen-Image-2.1 can "extract subjects from photos" with RGBA output — [Qwen-Image-2.1 README](https://raw.githubusercontent.com/QwenLM/Qwen-Image-2.1/main/README.md); mflux lists RGBA for Qwen Image 2.1 — [GitHub mflux](https://github.com/filipstrand/mflux)
- Qwen-Image-Edit-2511 includes a "generating new viewpoints" effect — [HF Qwen-Image-Edit-2511](https://huggingface.co/Qwen/Qwen-Image-Edit-2511)
- The numz SeedVR2 CLI preserves RGBA transparency — [numz README](https://raw.githubusercontent.com/numz/ComfyUI-SeedVR2_VideoUpscaler/main/README.md)
- MV-Adapter has a built-in `--remove_bg` and outputs 6 views — [GitHub MV-Adapter](https://github.com/huanngzh/MV-Adapter)

### Inferences
- Chain: photo → **Qwen-Edit-2511** or **FLUX.2 klein 4B**, with an instruction such as "the object alone, plain white background, front view" → **BiRefNet** for an RGBA cut-out (tier B) → **SeedVR2** to upscale small crops (alpha kept) → TRELLIS.2 / Pixal3D → UniRig. Every hop is image → image.
- Multiview (MV-Adapter, Zero123++) is worth a recipe only if a downstream 3D recipe accepts image_set, and both are tier B on Mac.

### Gaps
- Whether TRELLIS.2 or Pixal3D accept multi-image (image_set) input was not researched.

## 3. Ranked shortlist of recipe candidates (Mac-runnable)

### Takeaway
1. Qwen-Image-Edit-2511 via qwen-image-mps
2. FLUX.2 [klein] 4B via mflux
3. SeedVR2 via the numz CLI
4. BiRefNet (smoke-test first)
5. FLUX.1 Kontext [dev] or Fill via mflux
6. Qwen-Image-2.1 via mflux (watch-list)

### Cited Findings
1. **Qwen-Image-Edit-2511 via `qwen-image-mps edit`.** Its Mac path is confirmed, it is a PyTorch-MPS CLI (MIT), the weights are Apache-2.0, and it supports multi-image input with 8- and 4-step fast modes. It needs 64 GB+ and is slow on M1–M3 — [qwen-image-mps](https://github.com/ivanfioravanti/qwen-image-mps); [Willison](https://simonwillison.net/2025/Aug/19/qwen-image-edit/); [lilting.ch](https://lilting.ch/en/articles/comfyui-qwen-mps-bf16-slowdown)
2. **FLUX.2 [klein] 4B via mflux.** Apache-2.0, ~8 GB, instruction and multi-reference editing. The only strong editor for 16–32 GB Macs — [flux2 README](https://raw.githubusercontent.com/black-forest-labs/flux2/main/README.md); [mflux](https://github.com/filipstrand/mflux)
3. **SeedVR2 via numz `inference_cli.py`.** Apache-2.0, single image in with alpha kept, explicit MPS fixes, down to 8 GB with GGUF. The best upscale/restore step before 3D — [numz README](https://raw.githubusercontent.com/numz/ComfyUI-SeedVR2_VideoUpscaler/main/README.md)
4. **BiRefNet (tier B, smoke-test first).** MIT, `inference.py`, ~4 GB, no CUDA-only deps. Its photo → RGBA output is the most direct feeder for TRELLIS.2/Pixal3D. BEN2 (MIT) is the fallback — [BiRefNet](https://github.com/ZhengPeng7/BiRefNet); [BEN2](https://huggingface.co/PramaLLC/BEN2)
5. **FLUX.1 Kontext [dev] / Fill via mflux.** Mac path confirmed. Kontext is the only editor with documented low-drift multi-turn editing, and Fill is the only Mac-confirmed inpaint and outpaint option. Weights are non-commercial and gated, so the user needs a notice — [HF Kontext](https://huggingface.co/black-forest-labs/FLUX.1-Kontext-dev); [mflux](https://github.com/filipstrand/mflux)
6. **Qwen-Image-2.1 via mflux (watch-list).** 10 references, mask/annotation edits, RGBA subject extraction: an editor and a cut-out in one model. Research license, released 3 weeks ago — [Qwen-Image-2.1 README](https://raw.githubusercontent.com/QwenLM/Qwen-Image-2.1/main/README.md)

### Inferences
- Recipes 1 or 2, then 4, then 3 form a full "messy photo → 3D-ready RGBA image" pipeline. Of these, only #4 still needs a Mac smoke test.
- Honorable mentions: DreamO (MPS confirmed, but Gradio-only, so it needs a wrapper script and is not a clean recipe); MV-Adapter (tier B; worthwhile if image_set inputs land).

### Gaps
- No hands-on MPS runs back any ranking. Next step: smoke-test BiRefNet, the numz SeedVR2 CLI, and qwen-image-mps on a 16 GB and a 64 GB Mac.

### Excluded (no Mac path)
These are excluded because no Mac evidence was found and they have CUDA blockers, stale CUDA-only pins, or are unreleased. They were not researched further.
- SAM 3/3.1: CUDA 12.6+ GPU required.
- Official SeedVR repo: flash-attn + apex + H100.
- Step1X-Edit v1.2: forked diffusers, flash-attn, 18–50 GB.
- BAGEL: flash_attn==2.5.8 pinned.
- HiDream-E1.1: flash-attn prerequisite, gated Llama.
- ICEdit: NC, 35 GB.
- UniWorld-V2: finetunes of Qwen-Edit-2509/Kontext; use those bases via the paths above.
- InfiniteYou.
- PuLID: stale, Gradio-only.
- InstantID: stale.
- ACE++: FLUX work suspended.
- SUPIR: NC, two-GPU plus LLaVA-13B.
- Era3D: AGPL, xformers, tiny-cuda-nn, nvdiffrast.
- SV3D: gated NC.
- LaMa: torch 1.8 / cudatoolkit 10.2 pins.
- RMBG-2.0: NC and gated; superseded for Lift by BiRefNet.
- Z-Image-Edit: unreleased.
- FLUX.2 [dev] 32B: H100-class.

Sources for these exclusions: [sam3](https://github.com/facebookresearch/sam3), [SeedVR](https://github.com/ByteDance-Seed/SeedVR), [Step1X-Edit](https://raw.githubusercontent.com/stepfun-ai/Step1X-Edit/main/README.md), [Bagel](https://raw.githubusercontent.com/ByteDance-Seed/Bagel/main/README.md), [HiDream-E1](https://raw.githubusercontent.com/HiDream-ai/HiDream-E1/main/README.md), [ICEdit](https://raw.githubusercontent.com/River-Zhang/ICEdit/main/README.md), [UniWorld](https://raw.githubusercontent.com/PKU-YuanGroup/UniWorld/main/README.md), [InfiniteYou](https://raw.githubusercontent.com/bytedance/InfiniteYou/main/README.md), [PuLID](https://raw.githubusercontent.com/ToTheBeginning/PuLID/main/README.md), [InstantID](https://raw.githubusercontent.com/instantX-research/InstantID/main/README.md), [ACE++](https://raw.githubusercontent.com/ali-vilab/ACE_plus/main/README.md), [SUPIR](https://raw.githubusercontent.com/Fanghua-Yu/SUPIR/master/README.md), [Era3D](https://raw.githubusercontent.com/pengHTYX/Era3D/main/README.md), [SV3D](https://huggingface.co/stabilityai/sv3d), [LaMa](https://github.com/advimman/lama), [RMBG-2.0](https://huggingface.co/briaai/RMBG-2.0), [Z-Image status](https://howaiworks.ai/models/z-image), [flux2](https://raw.githubusercontent.com/black-forest-labs/flux2/main/README.md).
