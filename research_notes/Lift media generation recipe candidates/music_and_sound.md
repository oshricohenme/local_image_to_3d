# Mac-runnable music, sound-effect and video-to-audio models for Lift recipes (as of Oct 2026)

Scope (revised by the user): the catalog lists only models with evidence of a working Apple Silicon path. That path can be the upstream repo on PyTorch MPS or CPU (flash-attn or triton shims allowed), a community Mac port, or an MLX port. Each entry names its **runnable path** and the evidence for it. Models with no Mac path are listed in one line at the end. Every entry includes an **Editing** assessment (coordinator addendum). Unverified items are under Gaps.

---

## 1. Song generation with vocals and lyrics (Mac-runnable)

### Takeaway
Five song models have a Mac path. **ACE-Step 1.5** is the clear first recipe. It has official MPS and MLX support, MIT code and weights trained on licensed data, songs up to 10 min, and the richest editing set (repaint, cover, stem lego/extract/complete). **MiniMax-Music3** (via mlx-audio) is the frontier-quality alternative, with a commercial license that requires attribution. LeVo 2 (community MLX port), DiffRhythm v1.2 (official macOS support) and ACE-Step v1 (MPS) are secondary.

### Cited Findings

**ACE-Step 1.5**. Runnable path: **upstream repo, PyTorch MPS (`pt` LM backend) or the official MLX backend.**
- Evidence: the README says it "also supports MPS / ROCm / Intel XPU / CPU". It ships `start_gradio_ui_macos.sh` and `start_api_server_macos.sh`, which use an MLX backend on Apple Silicon, plus a macOS portable ZIP. — [GitHub ACE-Step-1.5](https://github.com/ace-step/ACE-Step-1.5)
- Community: the Gradio app failed on Mac until switched from vLLM ("does not run on Macs") to PyTorch, after which "it works". Apple Silicon only, not Intel. — [Pinokio](https://pinokio.co/posts/01kgn3t5byx2gdst9rwsgenjpw). Problems reported: a server kill (exit 9) on an M1 with 16 GB — [Pinokio bug](https://pinokio.co/posts/01kx2pprqggygwqtw84jfnbken) — and "MPS backend out of memory" on an M2 Air — [bioerrorlog](https://en.bioerrorlog.work/archive/category/macOS).
- Community MLX 8-bit XL-Turbo build: claims about 4 s per 30 s track on an unspecified M-series Mac (unverified). — [HF ddalcu](https://huggingface.co/ddalcu/ACE-Step-1.5-XL-Turbo-MLX-Serve-8bit)
- License: code MIT — [GitHub](https://github.com/ace-step/ACE-Step-1.5). Weights MIT. Training data is licensed tracks, royalty-free and public-domain music, and synthetic MIDI audio, and the card says outputs are commercially usable. — [HF ACE-Step/Ace-Step1.5](https://huggingface.co/ACE-Step/Ace-Step1.5). Not gated.
- Sizes: the DiT comes in a 2B tier (about 4.7 GB; base, sft, turbo at 8 steps) and a 4B XL tier (about 9 GB bf16, released 2026-04-02). The LM is Qwen3 at 0.6B, 1.7B or 4B. Memory tiers run from under 4 GB (INT8 plus offload) and 6–8 GB (2B turbo with 0.6B LM, `pt`) up to 24 GB or more (XL sft with 4B LM). Duration is 10 s to 10 min. vLLM is the default LM backend on larger tiers. Install is `uv sync` on Python 3.11–3.12. — [GitHub](https://github.com/ace-step/ACE-Step-1.5)
- Output defaults to 48 kHz, as flac, mp3, opus, aac, wav or wav32. — [INFERENCE.md](https://github.com/ace-step/ACE-Step-1.5/blob/main/docs/en/INFERENCE.md)
- Interfaces: Gradio (`uv run acestep`), REST (`uv run acestep-api`), a Python API (`acestep.inference.generate_music`), and a CLI that is "wizard/config only". `-c/--config file.toml` skips the wizard. — [CLI.md](https://github.com/ace-step/ACE-Step-1.5/blob/main/docs/en/CLI.md)
- **Editing:**
  - `cover`: `src_audio`, `caption`, `audio_cover_strength` (1.0 close, about 0.1 loose), optional `lyrics`.
  - `repaint`: `src_audio`, `repainting_start`, `repainting_end` (-1 means end of file), `caption`.
  - `lego` (base model only; adds a track): `src_audio`, `instruction` naming the track, `caption`.
  - `extract` (base only; isolates a track): `src_audio`, `instruction`.
  - `complete` (base only): `src_audio`, `instruction`, `caption`.
  - Track names: vocals, backing_vocals, drums, bass, guitar, keyboard, percussion, strings, synth, fx, brass, woodwinds.
  - `reference_audio` is an optional style input. The LM is skipped for cover, repaint and extract.
  - — [INFERENCE.md](https://github.com/ace-step/ACE-Step-1.5/blob/main/docs/en/INFERENCE.md)
- Speed on CUDA: under 2 s per song on an A100 and under 10 s on an RTX 3090. — [GitHub](https://github.com/ace-step/ACE-Step-1.5)

**ACE-Step v1 (3.5B, legacy)**. Runnable path: **upstream repo on MPS with `--bf16 false`.**
- Evidence: the README's macOS note says to use `--bf16 false`. Benchmark on a MacBook M2 Max: RTF 2.27x at 27 steps (26.4 s per minute of audio) and 1.03x at 60 steps. Apache-2.0. Up to about 4 min. — [GitHub ACE-Step](https://github.com/ace-step/ACE-Step)
- **Editing:** retake/variations (seed variance), repaint (start–end), lyric flow-edit (`only_lyrics` keeps the melody, `remix` changes it; small segments, chainable), and extend (left and right lengths). Gradio only. 1.5 is announced as the "latest and most advanced". — [GitHub ACE-Step](https://github.com/ace-step/ACE-Step)

**MiniMax-Music3 (~12B: 8B global LLM, 0.6B local LLM, 2.4B flow matching, 123M VAE)**. Runnable path: **MLX port in mlx-audio.**
- Evidence: support was merged in mlx-audio PR #888, installable from a pinned commit. CLI: `python -m mlx_audio.music.generate --model mlx-community/MiniMax-Music3-bf16 --caption --lyrics --duration --steps --seed --output`. Lyrics are required, and `[instrumental]` gives instrumental output. bf16 is 28.5 GB, with 8/6/4-bit, mxfp8, mxfp4 and nvfp4 builds. MXFP8 is recommended for lyric fidelity. — [HF mlx-community/MiniMax-Music3-bf16](https://huggingface.co/mlx-community/MiniMax-Music3-bf16), [4bit](https://huggingface.co/mlx-community/MiniMax-Music3-4bit). mlx-audio lists it as 44.1 kHz stereo. — [mlx-audio README](https://cdn.jsdelivr.net/gh/blaizzy/mlx-audio@main/README.md)
- Upstream: songs up to about 5 min. The upstream card gives 32 kHz (which conflicts with mlx-audio) and says "Inference requires CUDA" upstream. — [HF MiniMaxAI/MiniMax-Music3](https://huggingface.co/MiniMaxAI/MiniMax-Music3)
- License: the community license **allows commercial use**, but you must display "MiniMax-Music3" in the UI, businesses with more than $20M yearly revenue need written authorization, an AUP applies, and there is no territory limit. — [LICENSE](https://huggingface.co/MiniMaxAI/MiniMax-Music3/blob/main/LICENSE)
- **Editing:** none documented. Generation only.

**LeVo 2 / SongGeneration-v2 (Tencent, 4–5B, released 2026-03-01)**. Runnable path: **community MLX port `ailuntx/SongGeneration-MLX`** (MLX token generation plus the official PyTorch decoder on `mps`).
- Evidence: measured on Apple Silicon (medium, bf16), a 12 s song took about 1 min of MLX token generation plus 73 s of decoding, output as 48 kHz stereo FLAC. MLX large weights: bf16 10.2 GB, 8-bit 5.0 GB, 4-bit 2.7 GB. Two-step CLI: `python -m songgeneration_mlx.cli --lyrics --description --duration --output` writes tokens, then `scripts/decode_tokens_official.py --device mps`. Needs the official `runtime/` assets. — [HF mlx-community/songgeneration-v2-large](https://huggingface.co/mlx-community/songgeneration-v2-large)
- A Pinokio "SongGen-Mac" app also exists. — [Pinokio](https://beta.pinokio.co/apps/github-com-rdx-ai-art-songgen-mac)
- Upstream v2-large needs 22–28 GB of GPU memory and generates up to 4m30s. — [vllm-omni issue](https://goodfirstissue.org/vllm-project/vllm-omni/issues/3390). Tencent claims PER 8.55% versus Suno v5 at 12.4%. — [gaga.art](https://gaga.art/blog/songgeneration-2/)
- License unclear: the v1 card is Apache-2.0 — [HF](https://huggingface.co/lglg666/SongGeneration-base/blob/refs%2Fpr%2F1/README.md) — while a v2 GGUF port says "Commercial and production use are prohibited" — [HF LeVo2-GGUF](https://huggingface.co/ckadirt/LeVo2-GGUF).
- **Editing:** none documented in the port.

**DiffRhythm v1.2 (ASLP-lab)**. Runnable path: **upstream repo (official macOS support).**
- Evidence: README news item, "DiffRhythm can now run on MacOS!" (2025-03-11). Requires espeak-ng (available via brew). Scripts: `scripts/infer_wav_ref.sh` and `infer_prompt_ref.sh`. Apache-2.0 for code and DiT weights. base is 1m35s and full is 4m45s. 8 GB VRAM minimum with `--chunked`. — [GitHub DiffRhythm](https://github.com/ASLP-lab/DiffRhythm)
- **Editing:** v1.2 "enables song editing and continuation" (parameters not documented on the README). Style comes from a reference WAV or text. — [GitHub DiffRhythm](https://github.com/ASLP-lab/DiffRhythm)

### Inferences
- ACE-Step 1.5 maps cleanly to Lift. Lift writes a TOML from typed settings and runs `--config` (or makes a thin call to the repo's own Python API). On Mac it forces the `pt` LM backend, never vLLM, and defaults 16 GB Macs to 2B turbo with the 0.6B LM. The editing tasks map one-to-one onto an editing UI: repaint (time range plus caption), cover (strength slider), a track picker for lego/extract/complete, and reference-audio style.
- MiniMax-Music3 fits the "existing community Mac port" rule: pin mlx-audio at a commit. Default to 4-bit or mxfp8 to keep downloads reasonable. No editing UI.
- The LeVo 2 MLX port is slow (minutes per 12 s on medium) and its license is unclear, so treat it as lower priority.
- DiffRhythm v1.2 is a safe Apache-licensed fallback with official Mac support, but it is older.

### Gaps
- No primary-source M-series timing exists for ACE-Step 1.5 on MPS or MLX.
- Whether ACE-Step 1.5's `--config` CLI runs edit tasks non-interactively and prints parseable progress is undocumented.
- Whether 1.5 keeps v1's explicit extend, retake and lyric-edit modes is unclear. Its listed six tasks are text2music, cover, repaint, lego, extract and complete.
- MiniMax-Music3 Mac RAM needs and wall-clock speed are unpublished.
- The LeVo 2 license and official GitHub URL could not be verified (404/401 on fetch).

---

## 2. Instrumental / music and sound effects (Mac-runnable)

### Takeaway
**Stable Audio 3 Small (Music and SFX, 433M, May 2026)** is the best fit in this group. It runs on CPU, ships an official Apple Silicon CoreML/MLX runtime, is "a few seconds" per clip on an M4, and its `stable-audio` CLI exposes text-to-audio, audio-to-audio, inpainting and continuation as flags. **Magenta RealTime 2** is Mac-first (MLX, a `mrt` CLI, an AUv3 plugin). **MusicGen** runs on Mac only through workarounds (an MLX port, or MPS with mocked xformers), has non-commercial weights, and counts as legacy.

### Cited Findings

**Stable Audio 3 Small-Music / Small-SFX (433M each)**. Runnable path: **upstream repo on CPU; official Apple path is CoreML (DiT) + TFLite (decoder), plus an MLX/Metal runtime.**
- Evidence: the model table lists Small-Music and Small-SFX as "CPU", 120 s max. Medium (1.4B) is CUDA-only and requires Flash Attention 2, and "silent static output on Medium usually means flash-attn is broken". Large (2.7B) is API-only. — [GitHub stable-audio-3](https://github.com/Stability-AI/stable-audio-3)
- The HF card reports "a few seconds" on a MacBook Pro M4 and under 2 s on an H200. — [HF stable-audio-3-medium](https://huggingface.co/stabilityai/stable-audio-3-medium)
- Install is `uv sync` with optional `--extra ui` / `lora`. CLI: `stable-audio --model -p --duration -o --init-audio --init-noise-level --inpaint-audio --inpaint-start --inpaint-end --lora-ckpt-path --lora-strength`. — [GitHub](https://github.com/Stability-AI/stable-audio-3)
- Output is 44.1 kHz stereo. — [sonicfield](https://sonicfield.org/stable-audio-3)
- License: Stability AI Community License (free commercial use under $1M annual revenue), plus Gemma Terms for redistributed components. **Gated** (contact sharing). — [HF card](https://huggingface.co/stabilityai/stable-audio-3-medium), [Stability announcement](https://stability.ai/news-updates/meet-stable-audio-3-the-model-family-built-for-artistic-experimentation-with-open-weight-models). The repo sidebar says MIT, which conflicts with the README. — [GitHub](https://github.com/Stability-AI/stable-audio-3)
- Training data: 806,284 licensed AudioSparx recordings plus 472,618 Freesound CC recordings. — [HF card](https://huggingface.co/stabilityai/stable-audio-3-medium)
- **Editing (CLI-exposed):**
  - Audio-to-audio: `init_audio` plus `init_noise_level` (e.g. 0.9) plus a style prompt.
  - Inpainting: `inpaint_audio` with mask start/end seconds. Passing lists regenerates several non-contiguous regions in one pass.
  - Continuation: set the mask start to the source length and choose a longer duration.
  - LoRA style.
  - — [GitHub](https://github.com/Stability-AI/stable-audio-3)
- It supersedes Stable Audio Open 1.0 (47 s) and SAO Small (11 s). — [HF SAO 1.0](https://huggingface.co/stabilityai/stable-audio-open-1.0), [HF SAO Small](https://huggingface.co/stabilityai/stable-audio-open-small)

**Magenta RealTime 2 (Google; mrt2_small 230M, mrt2_base 2.4B)**. Runnable path: **upstream MLX backend + `mrt` CLI** (also a C++ engine, AUv3 plugin and macOS app).
- Evidence: "Real-time streaming requires Apple Silicon (M-series)". Only `mrt2_small` streams in real time on M1/M2 Pro and Air. CLI: `mrt models init`, `mrt models download`, `mrt mlx generate --prompt "disco funk" --duration 4.0 --model=mrt2_base`. Repo code is Apache-2.0. v1 is on the `v1_legacy` branch. — [GitHub magenta-realtime](https://github.com/magenta/magenta-realtime)
- Coverage is dated 2026-06-05. — [pasqualepillitteri.it](https://pasqualepillitteri.it/pt/news/tag/open+weights)
- v1 facts: weights CC-BY 4.0, 48 kHz stereo, 2 s chunks with 10 s context. Style can come from text, **an audio example**, or a weighted mix. Trained on about 190k hours of mostly instrumental stock music. — [HF google/magenta-realtime](https://huggingface.co/google/magenta-realtime)
- **Editing:** no waveform editing. Style steering from an audio example is documented for v1 and unverified for the MRT2 CLI.

**MusicGen / AudioCraft (Meta; 300M–3.3B, legacy)**. Runnable path: **community MLX port, or upstream on MPS with xformers mocked (`--no-deps`).**
- Evidence: an MLX MusicGen port took about 60 s for 9 s of audio on an M1 (2024). — [Nat Taylor](https://nattaylor.com/blog/2024/musicgen-via-mlx). An AudioCraft-on-MPS project installs audiocraft with `--no-deps`, mocks xformers, works only on Python 3.9–3.11, and reports about 18 s of compute per 1 s of audio (AudioGen). — [audiogen-mcp README](https://glama.ai/mcp/servers/@peerjakobsen/audiogen-mcp/blob/3e0060f6dca98c70b94c023f2136969a7692820c/README.md)
- License: code MIT, **weights CC-BY-NC 4.0**. Python 3.9, PyTorch 2.1.0. — [GitHub audiocraft](https://github.com/facebookresearch/audiocraft). 32 kHz. Upstream docs say "you must have a GPU". Gradio demo only. — [MUSICGEN.md](https://github.com/facebookresearch/audiocraft/blob/main/docs/MUSICGEN.md)
- **Editing:** melody conditioning via `generate_with_chroma(descriptions, melody, sr)` on melody models only, and continuation from an audio prompt. Both are in the Python API only. — [MUSICGEN.md](https://github.com/facebookresearch/audiocraft/blob/main/docs/MUSICGEN.md)

### Inferences
- One SA3 pin gives two recipes (Music and SFX) with a full editing UI driven by real CLI flags, which makes it the best editing fit in the catalog. Offer Small only. Medium on Mac depends on flash-attn 2, and a stand-in shim risks static output.
- MRT2 suits a "loops/backing bed" recipe. Its real-time strengths go beyond Lift's batch model.
- MusicGen's only unique feature (melody conditioning) is largely covered by ACE-Step cover and SA3 audio-to-audio. Low priority.

### Gaps
- Whether SA3's MLX/CoreML runtime is reachable through the same `stable-audio` CLI, or Small's CPU-speed on an M1 with 16 GB, is not documented.
- The MRT2 weights license and release date are not stated on the repo.

---

## 3. Video/image-to-audio (foley) (Mac-runnable)

### Takeaway
**No open foley model has documented evidence of a working Mac path.** MMAudio, HunyuanVideo-Foley, ThinkSound/PrismAudio and AudioX are all CUDA/Linux-documented with no Mac reports, and Kling-Foley has no open weights. So none qualify for the catalog under the revised scope. MMAudio is the candidate most worth a smoke test, because its CLI muxes audio onto a video and would chain with Lift's video outputs.

### Cited Findings
- MMAudio: "Tested only on Ubuntu". No Mac mention. CLI: `python demo.py --duration=8 --video=<path> --prompt "..."` writes FLAC plus MP4. About 6 GB in fp16. Code MIT, checkpoints CC-BY-NC. — [GitHub MMAudio](https://github.com/hkchengrex/MMAudio). A third-party Metal ops package lists MMAudio's 3D convolution as a gap it fills. — [PyPI mpsops](https://pypi.org/project/mpsops/)
- HunyuanVideo-Foley: CUDA 12.4/11.8 on Linux, no Mac mention. — [GitHub](https://github.com/Tencent-Hunyuan/HunyuanVideo-Foley). Its license excludes the EU, UK and South Korea. — [LICENSE](https://raw.githubusercontent.com/Tencent-Hunyuan/HunyuanVideo-Foley/main/LICENSE)
- ThinkSound: no Mac mention, and research-only. — [GitHub ThinkSound](https://github.com/FunAudioLLM/ThinkSound)
- Kling-Foley: no open weights found. — [ai-bot.cn](https://ai-bot.cn/kling-foley/)

### Inferences
- If Lift wants foley chained to generated video, MMAudio (small 44k checkpoint at 601 MB, or large v2) with `PYTORCH_ENABLE_MPS_FALLBACK=1` is the first thing to smoke-test. It is excluded from the catalog until it is proven.

### Gaps
- No MPS or CPU run reports exist for any foley model. This is the main hole in the audio lineup.

---

## 4. Audio utilities (Mac-runnable, brief)

### Takeaway
Stem separation runs well on Apple Silicon: `bs-roformer-infer` has an MLX backend and `audio-separator` has an MPS path. Whisper-family speech-to-text runs in mlx-audio. Stems pair with ACE-Step lego/repaint and SA3 inpainting.

### Cited Findings
- bs-roformer-infer: `backend` torch, mlx or auto, and `device` mps. MLX is about 2.5x faster than Torch-MPS on an M2 at roughly half the memory. — [GitHub bs-roformer-infer](https://github.com/openmirlab/bs-roformer-infer)
- audio-separator: RoFormer runs on PyTorch MPS, and ONNX MDX models use CoreML. Needs PyTorch 2.13+ on Apple Silicon. This is from a PR, and its merge status is unverified. — [PR #298](https://ithub.global.ssl.fastly.net/nomadkaraoke/python-audio-separator/pull/298/files)
- Mini-BS-RoFormer CoreML/MLX ports: the 18M model is MIT, and the 46.8M V2 is CC-BY-NC. — [HF schism-audio](https://huggingface.co/schism-audio/mini-bs-roformer-18m-coreml)
- Demucs: Meta's repo was archived 2025-01-01, and the maintained fork is adefossez/demucs (bug fixes only). — [GitHub demucs](https://github.com/facebookresearch/demucs)
- mlx-audio STT supports Whisper, Distil-Whisper, Parakeet and Qwen3-ASR, and offers SAM-Audio text-guided separation. — [mlx-audio README](https://cdn.jsdelivr.net/gh/blaizzy/mlx-audio@main/README.md)
- ACE-Step 1.5 `extract` isolates named stems natively. — [INFERENCE.md](https://github.com/ace-step/ACE-Step-1.5/blob/main/docs/en/INFERENCE.md)

### Inferences
- A stems recipe needs multi-file audio output (an audio_set type, or a zip) in Lift.

### Gaps
- BS-RoFormer community checkpoint licenses were not verified. Demucs Mac speed was not researched.

---

## 5. Comparison, editing support, and ranked shortlist

### Takeaway
Among Mac-runnable models, only **ACE-Step 1.5**, **ACE-Step v1** and **Stable Audio 3 Small** have documented waveform-preserving editing (time-range repaint or inpaint, continuation, audio-to-audio strength). SA3 is the only one whose editing is exposed as plain CLI flags.

### Cited Findings
- See the per-model citations above. The table below summarizes them.

### Inferences

| Model | Group | Runnable Mac path (evidence) | Code / weights license | Commercial | Gated | Size / memory | Max len / SR | CLI | CUDA deps to shim | Editing (modes → inputs; CLI?) |
|---|---|---|---|---|---|---|---|---|---|---|
| **ACE-Step 1.5** (2B / XL 4B) | Song+vocals | Upstream MPS (`pt`) + official MLX scripts; OOM/crash reports on 16 GB | MIT / MIT | Yes (licensed data) | No | 4.7–9 GB DiT + 0.6–4B LM; <4–24 GB tiers | 10 min / 48 kHz | Wizard or `--config .toml`; API; Gradio | vLLM (use `pt`) | repaint (src, start, end, caption); cover (src, strength, lyrics); lego/extract/complete (src, track; base model); ref-audio style. API yes; CLI via config (unverified for edits) |
| ACE-Step v1 (3.5B) | Song+vocals | Upstream MPS, `--bf16 false`; M2 Max RTF 2.27x | Apache / Apache | Yes | No | 8 GB with offload | ~4 min | Gradio `acestep` | none noted | retake, repaint, lyric flow-edit, extend L/R. Gradio only |
| MiniMax-Music3 (~12B) | Song+vocals | mlx-audio MLX port | Community license | Yes, attribution; >$20M revenue needs permission | No | 28.5 GB bf16; 4-bit builds | ~5 min / 44.1 kHz (mlx) or 32 kHz (upstream) | `python -m mlx_audio.music.generate` | n/a (MLX) | none |
| LeVo 2 / SongGen-v2 | Song+vocals | Community `SongGeneration-MLX` (+ PyTorch decoder on mps); 12 s ≈ 2+ min on Mac | ? (v1 Apache; v2 port says non-commercial) | Unclear | ? | 2.7–10.2 GB MLX weights | 4m30s / 48 kHz | 2-step CLI (tokens, then decode) | n/a | none |
| DiffRhythm v1.2 | Song+vocals | Upstream, "runs on macOS" (2025-03) | Apache / Apache | Yes | No | 8 GB (`--chunked`) | 4m45s | `infer_*_ref.sh` | none noted (espeak-ng) | editing + continuation (inputs undocumented); ref-WAV style |
| **Stable Audio 3 Small** Music / SFX (433M) | Instrumental + SFX | Upstream CPU; official CoreML/TFLite + MLX runtime; "few seconds" on M4 | MIT? / Stability Community | Yes under $1M revenue | Yes | Small, CPU-class | 120 s / 44.1 kHz | **`stable-audio`** | none for Small (Medium needs flash-attn 2) | audio-to-audio (`--init-audio`, `--init-noise-level`); inpaint (`--inpaint-audio/start/end`, multiple regions); continuation. **CLI yes** |
| Magenta RT2 (230M / 2.4B) | Instrumental (live) | Upstream MLX + `mrt` CLI; real-time on M1/M2 Pro (small) | Apache / ? (v1 CC-BY) | Likely | No | small to medium | streaming / 48 kHz | `mrt mlx generate` | none | style from audio example (v1); no waveform edit |
| MusicGen (300M–3.3B) | Instrumental | MLX port (M1: ~60 s per 9 s) or MPS with xformers mocked | MIT / CC-BY-NC | No | No | 16 GB GPU recommended upstream | 32 kHz | Gradio demo | xformers | melody (`generate_with_chroma`), continuation. Python API only |
| bs-roformer-infer / audio-separator | Stems | MLX backend (2.5x faster than MPS on M2) / MPS (PR) | Per checkpoint (MIT to CC-BY-NC) | Per checkpoint | No | small | – | CLI | none | n/a |
| Whisper (mlx-audio) | STT | mlx-audio | – | – | No | small | – | mlx-audio | none | n/a |

**Ranked shortlist (Mac-runnable only)**
1. **ACE-Step 1.5**: official Mac MPS and MLX support, MIT weights on licensed data, songs up to 10 min with vocals, and the deepest editing set (repaint, cover, stem lego/extract/complete) for Lift's editing UI. Its songs can serve as soundtracks for Lift's generated videos (mux step outside the model).
2. **Stable Audio 3 Small (Music + SFX)**: runs on CPU or Apple runtimes, takes seconds on an M4, and is the only model whose inpaint, continuation and audio-to-audio editing are plain CLI flags. One gated pin covers both instrumental and SFX.
3. **MiniMax-Music3 via mlx-audio**: the highest-quality vocal songs that run natively on Apple Silicon, under a commercial license with attribution. The trade-off is large downloads (use 4-bit or mxfp8) and no editing.
4. **Stem separation (bs-roformer-infer MLX / audio-separator)**: a cheap, fast utility that feeds ACE-Step lego/repaint and SA3 inpainting.
5. **Magenta RealTime 2**: Mac-native instrumental loops and beds with a simple `mrt` CLI. (Fallbacks: DiffRhythm v1.2 for Apache songs; the LeVo 2 MLX port if its license clears.)

No foley (video-to-audio) model qualifies yet, so nothing chains audio onto Lift's video outputs directly. MMAudio is the first smoke-test candidate (see section 3).

### Gaps
- Stdout progress formats for the ACE-Step `--config` CLI, `stable-audio`, `mlx_audio.music.generate` and `mrt` were not verified.
- None of the Mac timings are from a controlled benchmark across 16 GB and 64 GB+ machines.

---

**Excluded (no Mac path):** YuE2/YuE (Linux plus 24 GB NVIDIA only), HeartMuLa, SongBloom (official repos reportedly deleted), DiffRhythm 2, WanSong (weights unconfirmed), Stable Audio 3 Medium (needs flash-attn 2), Stable Audio Open 1.0/Small (superseded, no Mac evidence), TangoFlux, AudioX, AudioLDM2/Tango 2/EzAudio (not researched), MMAudio, HunyuanVideo-Foley, ThinkSound/PrismAudio, Kling-Foley (not open).
