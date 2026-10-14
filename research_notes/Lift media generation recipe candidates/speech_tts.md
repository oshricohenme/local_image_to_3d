# Open-weight speech generation models (TTS, cloning, dialogue, voice conversion, editing) as Lift recipe candidates (October 2026)

Notes on method and confidence:
- Research date: 2026-10-11. Primary sources fetched this session: GitHub READMEs for mlx-audio, VibeVoice, Chatterbox, Dia2, fish-speech, Qwen3-TTS, Step-Audio-EditX, F5-TTS (plus the raw `speech_edit.py`), Seed-VC, IndexTTS, CosyVoice, Higgs Audio, VoxCPM, Kyutai DSM, VoiceCraft, OmniVoice, RVC, idiap coqui-ai-TTS, Zonos, PlayDiffusion, Amphion, MegaTTS3, Spark-TTS; HF cards for Kokoro-82M and Higgs Audio v3; the live Artificial Analysis Speech Arena page.
- Rows marked **(unverified)** come from prior knowledge (mid-2025 and earlier). I did not re-fetch them this session. Treat them as leads to check, not facts.
- "MPS not mentioned" means the README says nothing about it. It does not mean MPS fails.

---

## Catalog overview: Mac-runnable models only (comparison table incl. Editing column)

Scope (per the coordinator): this catalog only includes models with evidence of at least one Mac path. A path is upstream PyTorch MPS/CPU, a community Mac port, or an MLX port in mlx-audio. Models with no Mac path found are listed in one line at the end of Q8 under "Excluded (no Mac path)". Sections Q1–Q7 keep some data on excluded models for context only.

### Takeaway
Most current permissive leaders have a Mac path, and **mlx-audio is the single biggest enabler**. It ports Kokoro, Chatterbox, Qwen3-TTS, VoxCPM2, OmniVoice, CSM, Dia v1, Spark, Higgs v2/v3, Voxtral, MOSS-TTS, MeloTTS and others. Upstream PyTorch MPS is explicitly supported by Chatterbox, F5-TTS (`speech_edit.py`), VoxCPM2, OmniVoice and Seed-VC. On a Mac, editing narrows to: word replacement (F5-TTS `speech_edit.py`), voice conversion (Chatterbox VC, Seed-VC, Coqui `tts` VC on CPU) and continuation (Dia2, VoxCPM2, CSM). Emotion/style editing (Step-Audio-EditX) has **no Mac path**.

### Cited Findings

| Model (developer) | Mac runnable path + evidence | Size | Langs | License (code / weights) | Cloning | AA Elo (open) | Editing (modes → inputs → CLI?) |
|---|---|---|---|---|---|---|---|
| **Kokoro-82M v1.0** (hexgrad) | **MLX** (mlx-audio `mlx-community/Kokoro-82M-bf16`/8/6/4-bit) — [mlx-audio](https://github.com/Blaizzy/mlx-audio); 22x real time bf16 on M4 Max, 11.9x on M1 Max — [vllm-mlx](https://vllm-mlx.is-a.dev/benchmarks/audio.md); CoreML RTF 0.17 on M5 Pro — [soniqo](https://soniqo.audio/es/benchmarks). Upstream pip `kokoro` (PyTorch) — [HF](https://huggingface.co/hexgrad/Kokoro-82M) | 82M | 8 | Apache-2.0 / Apache-2.0 | No (54 presets) | 1064 | None |
| **Chatterbox** Turbo 350M / Nano 110M / Multilingual V3 ~500M (Resemble AI) | **Upstream MPS**: repo ships `example_for_mac.py`; multilingual example lists `"mps"`; Nano runs on CPU — [Chatterbox](https://github.com/resemble-ai/chatterbox). **MLX**: `chatterbox-multilingual-v3`, `chatterbox-fp16` — [mlx-audio](https://github.com/Blaizzy/mlx-audio) | 110M–500M | EN; 23 (Multilingual) | MIT / MIT; Perth watermark | Yes | 1026 | **Voice conversion**: `example_vc.py` (source recording + target voice clip); args not inspected |
| **F5-TTS v1 / E2-TTS** (SWivid) | **Upstream MPS**: `speech_edit.py` picks MPS automatically and sets `PYTORCH_ENABLE_MPS_FALLBACK=1` — [speech_edit.py](https://raw.githubusercontent.com/SWivid/F5-TTS/main/src/f5_tts/infer/speech_edit.py); README gives Apple Silicon torch install — [F5-TTS](https://github.com/SWivid/F5-TTS). No M-series RTF found | (unverified ~336M) | ZH/EN base | MIT / CC-BY-NC | Yes (ref audio + text) | n/a | **Word replacement/infilling**: source audio, full edited transcript, `parts_to_edit` [start,end] s, `fix_duration`. Hardcoded vars, **no CLI args** (needs wrapper) |
| **VoxCPM2** (OpenBMB) | **Upstream MPS**: demo `--device mps`, `auto` picks MPS; **llama.cpp-omni Metal** RTF ~1.76 Q8_0 on M4 Pro — [VoxCPM](https://github.com/OpenBMB/VoxCPM); **MLX** `mlx-community/VoxCPM2-bf16`/8/4-bit — [mlx-audio](https://github.com/Blaizzy/mlx-audio) | 2B (~8 GB) | 30 | Apache-2.0, commercial OK | Yes + voice design | n/a | **Continuation** ("ultimate cloning" from ref audio + transcript). CLI `voxcpm clone` |
| **Qwen3-TTS** 0.6B/1.7B (Alibaba) | **MLX**: `Qwen3-TTS-12Hz-*` incl. VoiceDesign/CustomVoice — [mlx-audio](https://github.com/Blaizzy/mlx-audio); M5 Pro 1.7B RTF 0.79 (4-bit) / 0.85 (8-bit) — [soniqo](https://soniqo.audio/es/benchmarks). Upstream examples use `cuda:0` plus flash-attn (recommended, not required; shim-able) — [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS) | 0.6B / 1.7B | 10 | Apache-2.0 | 3 s clone; VoiceDesign | n/a | None |
| **OmniVoice** (k2-fsa) | **Upstream MPS**: `device_map="mps"`, torch 2.8.0 — [OmniVoice](https://github.com/k2-fsa/OmniVoice); **MLX** `mlx-community/OmniVoice-bf16` — [mlx-audio](https://github.com/Blaizzy/mlx-audio) | not stated | 600+ | Apache-2.0 code / weights not stated | 3–10 s ref; voice design | n/a | None |
| **Fun-CosyVoice3-0.5B** (Alibaba) | **Community port**: M5 Pro benchmark of CosyVoice3 0.5B 4-bit, RTF 0.59 — [soniqo](https://soniqo.audio/es/benchmarks). Upstream Mac support not mentioned — [CosyVoice](https://github.com/FunAudioLLM/CosyVoice) | 0.5B | 9 + 18 dialects | Apache-2.0 | Zero-shot, cross-lingual, instruct | n/a | VC only for older CosyVoice-300M |
| **Dia2** 1B/2B (Nari Labs) | **Upstream CPU** fallback in `dia2.cli` (`--device` override; MPS not mentioned, speed unverified) — [Dia2](https://github.com/nari-labs/dia2). mlx-audio ports only **Dia v1** 1.6B — [mlx-audio](https://github.com/Blaizzy/mlx-audio) | 1B / 2B | EN | Apache-2.0 | Prefix-speaker audio | n/a | **Continuation** (`--prefix-speaker-1/-2`). CLI yes |
| **Sesame CSM-1B** (+ MisoTTS finetune) | **MLX** `mlx-community/csm-1b`, with `--ref_audio` cloning example — [mlx-audio](https://github.com/Blaizzy/mlx-audio) | 1B | EN | Apache-2.0 ([secondary](https://codersera.com/blog/orpheus-3b-tts-vs-sesame-csm-1b-ai-speech-synthesis-for-emotion-conversational-depth/amp/)) | Yes | n/a | Context continuation (unverified) |
| **Higgs Audio v3** (Boson AI) | **MLX** `bosonai/higgs-audio-v3-tts-4b` — [mlx-audio](https://github.com/Blaizzy/mlx-audio). Upstream is SGLang/vLLM serving only — [HF](https://huggingface.co/bosonai/higgs-audio-v3-tts-4b) | 4–5B (~10 GB BF16, est.) | 100+ | Apache repo / **research & NC** weights (creator grant) | Yes | 1036 | None |
| **Higgs Audio v2** (Boson AI) | **MLX** `higgs-audio-v2-3B-mlx-q8/q6` — [mlx-audio](https://github.com/Blaizzy/mlx-audio) | 3B | EN, ZH, KO, DE, ES | (unverified) Boson community license | Yes, multi-speaker | n/a | None |
| **Voxtral TTS** (Mistral) | **MLX** `Voxtral-4B-TTS-2603-mlx-bf16`, 20 voices — [mlx-audio](https://github.com/Blaizzy/mlx-audio) | 4B | 9 | CC BY-NC 4.0 — [DataNorth](https://datanorth.ai/news/mistral-releases-voxtral-tts-open-weight-text-to-speech-model) | Fixed voices in open weights | 1086 | None |
| **Kyutai TTS** (DSM) | **Official MLX** `scripts/tts_mlx.py` (moshi-mlx, `--quantize 8/4`) — [Kyutai DSM](https://github.com/kyutai-labs/delayed-streams-modeling) | (unverified 1.6B) | (unverified EN/FR) | MIT/Apache code; weights license not on README | (unverified) | n/a | None |
| **Spark-TTS-0.5B** | **MLX** `Spark-TTS-0.5B-bf16` — [mlx-audio](https://github.com/Blaizzy/mlx-audio) | 0.5B | ZH/EN | Apache-2.0 repo — [Spark-TTS](https://github.com/SparkAudio/Spark-TTS) | Yes; gender/pitch/speed | n/a | None |
| **Orpheus 3B** (Canopy Labs) | **Community port**: GGUF via LM Studio (Metal) plus a SNAC decoder; upstream package fails on Mac with a CUDA error — [Codersera guide](https://codersera.com/blog/install-and-run-orpheus-3b-tts-on-macos-a-complete-guide/amp/) (secondary) | 3B | EN + multilingual family | Apache-2.0 (secondary) | Yes; emotion tags | n/a | None |
| **Zonos v0.1** transformer (Zyphra) | **Upstream macOS** listed as supported (transformer variant; hybrid needs NVIDIA); MPS not mentioned, so likely CPU and slow — [Zonos](https://github.com/Zyphra/Zonos) | not stated | EN, JA, ZH, FR, DE | Apache-2.0 | Yes | 1000 | None |
| **XTTS-v2 + Coqui VC models** (idiap fork) | **Upstream CPU**: macOS wheels since 0.24.2; MPS not mentioned — [idiap](https://github.com/idiap/coqui-ai-TTS) | (unverified ~470M) | 17 | MPL-2.0 / CPML (NC) | 6 s clip | 916 | **VC**: `tts --source_wav --target_wav` (FreeVC/OpenVoice). CLI yes |
| **Seed-VC** (Plachtaa) | **Upstream Mac**: `requirements-mac.txt` (2025-03-03); real-time GUI needs Tkinter Python — [Seed-VC](https://github.com/Plachtaa/seed-vc) | 25M–200M | any | GPL-3.0; **archived 2025-11-21** | n/a | n/a | **VC/singing VC**: `inference.py --source --target`; v2 `--convert-style`, `--anonymization-only`. CLI yes |
| **MeloTTS** (MyShell) | **MLX** `MeloTTS-English-MLX` — [mlx-audio](https://github.com/Blaizzy/mlx-audio); CPU real time — [BentoML](https://www.bentoml.com/blog/exploring-the-world-of-open-source-text-to-speech-models) | small | EN (MLX) | MIT | No | n/a | None |
| **Other mlx-audio TTS ports (2026)** | **MLX**: KittenTTS nano/micro/mini (EN), Soprano-1.1-80M (EN), OuteTTS-1.0-0.6B, MOSS-TTS v1.5 8B (31 langs, cloning), MOSS-TTS-Nano-100M (20 langs, cloning), LongCat-AudioDiT-1B (ZH/EN, cloning), KugelAudio-7B (~17 GB), Ming-omni-tts 0.5B and 16.8B-A3B, rumik-oss-1 3B (Indic) — [mlx-audio](https://github.com/Blaizzy/mlx-audio) | various | various | not checked | various | n/a | None documented |

### Inferences
- Commercial-friendly **and** Mac-runnable: Kokoro, Chatterbox, VoxCPM2, Qwen3-TTS, OmniVoice, CosyVoice3, Dia2 (CPU), CSM, Spark, Zonos (CPU), MeloTTS.
- Mac editing backends:
  - Word replacement: F5-TTS `speech_edit.py`, which needs a thin wrapper and has NC weights.
  - Voice conversion: Chatterbox `example_vc.py` (MIT), Seed-VC (GPL, archived), Coqui VC (CPU, MPL code).
  - Continuation: Dia2, VoxCPM2, CSM.
  - Nothing Mac-runnable offers emotion/style editing of an existing clip.
- An "mlx-audio engine recipe" (pin mlx-audio at a commit, choose a model per recipe) would cover about 20 models with one CLI (`mlx_audio.tts.generate`).

### Gaps
- PyTorch-MPS RTF and peak memory are unmeasured for Chatterbox, F5-TTS, VoxCPM2, OmniVoice and Dia2. Whether Dia2 works on MPS (not only CPU) is unknown.
- MLX ports may not expose every upstream feature (e.g., Chatterbox VC, Qwen3 VoiceDesign arguments). I did not check this.

---

## Q1. Official repo, CLI vs Gradio/server only, pip-installable?

### Takeaway
The best CLI fits are Chatterbox (pip `chatterbox-tts` plus example scripts), F5-TTS (pip `f5-tts`, `f5-tts_infer-cli`), Kokoro (pip `kokoro`), VoxCPM2 (pip `voxcpm`, `voxcpm clone/design/batch`), OmniVoice (pip `omnivoice`, `omnivoice-infer`), Dia2 (`python -m dia2.cli`), Spark (`python -m cli.inference`), MegaTTS3 (`tts/infer_cli.py`), Seed-VC (`inference.py`), Step-Audio-EditX (`tts_infer.py`), Coqui (`tts`) and mlx-audio (`mlx_audio.tts.generate`). Several flagship models are server-first: Higgs v3 serves only through SGLang-Omni/vLLM-Omni, Qwen3-TTS offers a Python API plus Gradio, IndexTTS2 a WebUI plus Python API, and RVC and PlayDiffusion are WebUI only.

### Cited Findings
- mlx-audio: `pip install mlx-audio`; CLI `mlx_audio.tts.generate --model <hf-id> --text ... --voice ...`; cloning with `--ref_audio`; ffmpeg needed for non-WAV output — [mlx-audio](https://github.com/Blaizzy/mlx-audio)
- Chatterbox: `pip install chatterbox-tts`; scripts `example_tts.py`, `example_tts_turbo.py`, `example_tts_nano.py`, `example_vc.py`, `example_for_mac.py`; developed on Python 3.11 with pinned deps — [Chatterbox](https://github.com/resemble-ai/chatterbox)
- F5-TTS: `pip install f5-tts`; `f5-tts_infer-cli --ref_audio --ref_text --gen_text` or `-c` TOML; `f5-tts_infer-gradio` — [F5-TTS](https://github.com/SWivid/F5-TTS)
- Kokoro: pip `kokoro` ≥0.9.2, uses `misaki` G2P and installs `espeak-ng` in the example — [Kokoro HF](https://huggingface.co/hexgrad/Kokoro-82M)
- VoxCPM2: `pip install voxcpm`; CLI `voxcpm design`, `voxcpm clone`, `voxcpm batch`; Python 3.10–3.12, PyTorch ≥2.5 — [VoxCPM](https://github.com/OpenBMB/VoxCPM)
- OmniVoice: `pip install omnivoice`; `omnivoice-infer`, `omnivoice-infer-batch`, `omnivoice-demo` — [OmniVoice](https://github.com/k2-fsa/OmniVoice)
- Dia2: `uv run -m dia2.cli --hf nari-labs/Dia2-2B --input input.txt --cfg 6.0 --temperature 0.8 [--cuda-graph] output.wav`; auto CUDA, else CPU; `--device`/`--dtype` overrides; Gradio `gradio_app.py` — [Dia2](https://github.com/nari-labs/dia2)
- Qwen3-TTS: `pip install -U qwen-tts`; main interface is the Python API `Qwen3TTSModel`; `qwen-tts-demo` Gradio; vLLM-Omni — [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS)
- Higgs v3: self-host with `sgl-omni serve` or `vllm-omni serve`, using OpenAI-style `/v1/audio/speech`; the Transformers snippet on the card is auto-generated and not stated as supported — [Higgs v3 HF](https://huggingface.co/bosonai/higgs-audio-v3-tts-4b), [higgs-audio](https://github.com/boson-ai/higgs-audio)
- Fish S2: command-line inference, WebUI, server, Docker, SGLang and vLLM-Omni — [fish-speech](https://github.com/fishaudio/fish-speech)
- IndexTTS2: `uv run webui.py --version 2`; Python `indextts.infer_v2.IndexTTS2`; README warns that `infer_v2.py` runs a benchmark loop against a hardcoded `checkpoints/` directory — [index-tts](https://github.com/index-tts/index-tts)
- CosyVoice: `python example.py`, `vllm_example.py`, `webui.py`, gRPC/FastAPI servers — [CosyVoice](https://github.com/FunAudioLLM/CosyVoice)
- Kyutai: `scripts/tts_pytorch.py` (text file or stdin), `tts_pytorch_streaming.py`, `tts_mlx.py` (moshi-mlx), Rust server — [Kyutai DSM](https://github.com/kyutai-labs/delayed-streams-modeling)
- Zonos: `sample.py` minimal CLI (reloads the model each run); Gradio recommended — [Zonos](https://github.com/Zyphra/Zonos)
- Spark-TTS: `python -m cli.inference --text --device --save_dir --model_dir --prompt_text --prompt_speech_path` — [Spark-TTS](https://github.com/SparkAudio/Spark-TTS)
- MegaTTS3: `tts/infer_cli.py --input_wav --input_text --output_dir --p_w --t_w` — [MegaTTS3](https://github.com/bytedance/MegaTTS3)
- Step-Audio-EditX: all modes through `tts_infer.py --edit-type ...`; `app.py` web demo; setup with `uv sync` — [Step-Audio-EditX](https://github.com/stepfun-ai/Step-Audio-EditX)
- Coqui fork: pip `coqui-tts` (0.27.x); `tts --text --model_name --out_path`; VC with `--source_wav --target_wav` — [idiap/coqui-ai-TTS](https://github.com/idiap/coqui-ai-TTS)
- Seed-VC: `inference.py` / `inference_v2.py` with full CLI args; Gradio apps; `real-time-gui.py` — [Seed-VC](https://github.com/Plachtaa/seed-vc)
- RVC: README documents only `python webui.py` — [RVC](https://github.com/RVC-Project/Retrieval-based-Voice-Conversion-WebUI)
- VibeVoice: README documents no TTS CLI or Gradio; the TTS code was removed — [VibeVoice](https://github.com/microsoft/VibeVoice)

### Inferences
- mlx-audio is one pip package with one CLI covering about 20 models (Kokoro, Chatterbox, Qwen3-TTS, VoxCPM2, OmniVoice, CSM, Dia v1, Spark, Higgs v2/v3, Voxtral, MOSS). It could be a single "engine recipe" with per-model settings. That bends the "pin one upstream repo, run its own CLI" rule but would fit it if mlx-audio itself is the pinned repo.

### Gaps
- Exact Higgs v2 `examples/generation.py` arguments and Orpheus/CSM/Parler/OpenVoice CLIs were not re-verified this session.

---

## Q2. Licenses (code vs weights), commercial use, gating, consent and watermarking

### Takeaway
Fully permissive (code and weights): Kokoro (Apache), Chatterbox (MIT, watermarked), Qwen3-TTS (Apache), VoxCPM2 (Apache, commercial stated), CosyVoice (Apache), Dia2 (Apache), Zonos (Apache), MegaTTS3 (Apache), VibeVoice (MIT, but TTS code pulled), RVC (MIT). Non-commercial weights: F5-TTS (CC-BY-NC), Fish S2 Pro (research license, paid commercial), Higgs v3 (research/NC, with a creator grant), Voxtral TTS (CC BY-NC), Breeze TTS 2 (research/NC), XTTS-v2 (CPML), VoiceCraft (CC BY-NC-SA code plus CPML). Seed-VC is GPL-3.0.

### Cited Findings
- Kokoro: Apache-2.0 — [Kokoro HF](https://huggingface.co/hexgrad/Kokoro-82M)
- Chatterbox: MIT; every output carries a Perth watermark that survives MP3, with a detection script provided — [Chatterbox](https://github.com/resemble-ai/chatterbox)
- F5-TTS: code MIT; pre-trained models CC-BY-NC because of Emilia data — [F5-TTS](https://github.com/SWivid/F5-TTS)
- Fish S2 Pro: "Fish Audio Research License"; research and non-commercial use free; commercial use needs a separate license (business@fish.audio); license updated March 7 2026; Fish calls it "open weights, not open source" — [fish.audio S2](https://fish.audio/s2/), [HF LICENSE](https://huggingface.co/fishaudio/s2-pro/blob/main/LICENSE.md), [fish.audio developers](https://fish.audio/en/developers/)
- Higgs v3: Boson Higgs TTS 3 Research and Non-Commercial License; production, hosted and embedded use need a commercial license; a Creator Use Grant allows monetized creator content with credit — [Higgs v3 HF](https://huggingface.co/bosonai/higgs-audio-v3-tts-4b)
- Voxtral TTS: CC BY-NC 4.0 weights, a change from Apache on earlier Voxtral models; commercial use via API at $0.016/1k chars — [DataNorth](https://datanorth.ai/news/mistral-releases-voxtral-tts-open-weight-text-to-speech-model), [Slator](https://slator.com/mistral-text-to-speech-model/)
- Breeze TTS 2: code Apache-2.0; weights "breezeblue-research-and-non-commercial-license"; commercial use needs written authorization from BreezeBlue/RESONIA; tokenizer based on Qwen3-TTS — [WaveSpeed review](https://wavespeed.ai/blog/commercial-compliance/breeze-tts-2-review/), [HF discussion](https://huggingface.co/BreezeBlue/Breeze-TTS-2/discussions/8)
- Qwen3-TTS: Apache-2.0 — [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS)
- VoxCPM2: Apache-2.0, "free for commercial use" — [VoxCPM](https://github.com/OpenBMB/VoxCPM)
- CosyVoice: Apache-2.0 — [CosyVoice](https://github.com/FunAudioLLM/CosyVoice)
- IndexTTS: bilibili Model Use License Agreement; commercial use via indexspeech@bilibili.com — [index-tts](https://github.com/index-tts/index-tts)
- Dia2: Apache-2.0; the Kyutai Mimi codec keeps its own license — [Dia2](https://github.com/nari-labs/dia2)
- VibeVoice: MIT; TTS code removed 2025-09-05 over use "inconsistent with the stated intent" — [VibeVoice](https://github.com/microsoft/VibeVoice)
- Zonos Apache-2.0 — [Zonos](https://github.com/Zyphra/Zonos); MegaTTS3 Apache-2.0, "primarily intended for academic use", WaveVAE encoder withheld "for security reasons" — [MegaTTS3](https://github.com/bytedance/MegaTTS3); Spark-TTS repo Apache-2.0, weights license not stated on README — [Spark-TTS](https://github.com/SparkAudio/Spark-TTS)
- Step-Audio-EditX: code Apache-2.0; weights license not stated on README — [Step-Audio-EditX](https://github.com/stepfun-ai/Step-Audio-EditX)
- XTTS-v2: Coqui shut down in early 2024; model under CPML (non-commercial); community maintained — [BentoML](https://www.bentoml.com/blog/exploring-the-world-of-open-source-text-to-speech-models); idiap fork code MPL-2.0 — [idiap](https://github.com/idiap/coqui-ai-TTS)
- VoiceCraft: code CC BY-NC-SA 4.0, weights CPML 1.0.0 — [VoiceCraft](https://github.com/jasonppy/VoiceCraft); README forbids generating or editing someone's speech without consent — [arXiv/README via search](https://arxiv.org/html/2403.16973v1)
- Seed-VC GPL-3.0 — [Seed-VC](https://github.com/Plachtaa/seed-vc); RVC MIT — [RVC](https://github.com/RVC-Project/Retrieval-based-Voice-Conversion-WebUI); Amphion MIT code, Emilia data CC BY-NC 4.0 — [Amphion](https://github.com/open-mmlab/Amphion); PlayDiffusion code Apache-2.0, checkpoint license not stated — [PlayDiffusion](https://github.com/playht/PlayDiffusion)
- NeuTTS Air output includes Perth watermarks — [BentoML](https://www.bentoml.com/blog/exploring-the-world-of-open-source-text-to-speech-models)

### Inferences
- Lift should show a license badge (commercial OK / non-commercial) and, for cloning and VC recipes, a consent notice. Chatterbox's watermark is a selling point for responsible cloning.

### Gaps
- HF gating status was not confirmed for any of these. Fish, Higgs v3 and Breeze cards may require accepting terms (unverified). Lift already supports gated repos.

---

## Q3. Size, memory, languages, max length

### Takeaway
Tiny: Kokoro 82M, Chatterbox Nano 110M, Seed-VC 25M–200M. Small: Chatterbox Turbo 350M, Chatterbox Multilingual ~500M, CosyVoice3 0.5B, Spark 0.5B, MegaTTS3 0.45B, Qwen3-TTS 0.6B/1.7B. Mid: Dia2 1B/2B, VoxCPM2 2B (~8 GB VRAM), Step-Audio-EditX 3B (12–16 GB), Higgs v2 3B, Breeze 3B. Large: Fish S2 Pro ~4.4B, Higgs v3 4–5B (~10 GB BF16), Voxtral 4B, MOSS-TTS 8B, KugelAudio 7B (~17 GB). All fit 16 GB Macs except the largest, which need 32 GB+.

### Cited Findings
- Chatterbox sizes: Turbo 350M, Nano 110M, Multilingual V3 ~500M (23 languages); six single-language 500M finetunes — [Chatterbox](https://github.com/resemble-ai/chatterbox)
- Dia2: 1B/2B; English only; up to ~2 minutes (1500 context steps) — [Dia2](https://github.com/nari-labs/dia2)
- VibeVoice 1.5B: up to ~90 min, up to 4 speakers, EN/ZH; Realtime 0.5B single-speaker — [BentoML](https://www.bentoml.com/blog/exploring-the-world-of-open-source-text-to-speech-models), [VibeVoice](https://github.com/microsoft/VibeVoice)
- VoxCPM2: 2B, 30 languages, 48 kHz output, ~8 GB VRAM, RTF ~0.30 on RTX 4090 — [VoxCPM](https://github.com/OpenBMB/VoxCPM)
- Step-Audio-EditX: 3B; 12 GB minimum, 16 GB recommended; memory-efficient mode 6–8 GB, AWQ 4-bit 8–10 GB — [Step-Audio-EditX](https://github.com/stepfun-ai/Step-Audio-EditX)
- Higgs v3: 100+ languages (85 production-quality); card lists 5B params BF16 — [Higgs v3 HF](https://huggingface.co/bosonai/higgs-audio-v3-tts-4b)
- Fish S2 Pro: 4B slow AR + 400M fast AR; 80+ languages — [fish-speech](https://github.com/fishaudio/fish-speech)
- Qwen3-TTS: 0.6B/1.7B; 10 languages — [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS)
- CosyVoice3 0.5B: 9 languages + 18 dialects — [CosyVoice](https://github.com/FunAudioLLM/CosyVoice)
- IndexTTS-2.5 (2026-08-10): ZH/EN/JA/ES/AR; `duration_factor` 0.5–2.0x; RTF 0.2065 BF16 on RTX 4090 — [index-tts](https://github.com/index-tts/index-tts)
- KugelAudio 7B (~17 GB memory); MOSS-TTS 8B, 31 languages; MOSS-TTS-Nano 100M — [mlx-audio](https://github.com/Blaizzy/mlx-audio)
- Zonos: ≥6 GB VRAM; 44 kHz; 5 languages; ~2x real-time on RTX 4090 — [Zonos](https://github.com/Zyphra/Zonos)
- Seed-VC sizes 25M / 98M / 200M; v2 67M + 90M — [Seed-VC](https://github.com/Plachtaa/seed-vc)
- Voxtral TTS 4B, 9 languages — [DataNorth](https://datanorth.ai/news/mistral-releases-voxtral-tts-open-weight-text-to-speech-model)
- VoiceCraft TTS-finetuned 330M: prompt + generation ≤16 s — [VoiceCraft](https://github.com/jasonppy/VoiceCraft)

### Inferences
- Most models generate up to ~30 s per call. Long-form output (audiobooks) needs chunking, which Lift could do as a settings-driven loop, though that is outside "run the repo's CLI". Only VibeVoice (code gone) and Dia2 (2 min) natively target long multi-speaker output.

### Gaps
- Max lengths for Chatterbox, Qwen3-TTS, VoxCPM2 and OmniVoice are not documented on the fetched pages.

---

## Q4. Apple Silicon status (MPS / CPU / MLX ports, RTF on M-series)

### Takeaway
MLX (mlx-audio) is the best-supported Mac path and covers most permissive leaders. Native PyTorch MPS is explicitly supported by OmniVoice, VoxCPM2 (demo `--device mps`), Chatterbox (`"mps"` option plus `example_for_mac.py`), F5-TTS (`speech_edit.py` auto-MPS) and Seed-VC (`requirements-mac.txt`). Kyutai ships an official MLX script. Orpheus's upstream package fails on Mac (CUDA-only path). Dia2 falls back to CPU. Published M-series RTF figures are scarce.

### Cited Findings
- Kokoro (mlx-audio): bf16 22x real-time and 4-bit 20x on M4 Max; 11.9x and 15.5x on M1 Max — [vllm-mlx benchmarks](https://vllm-mlx.is-a.dev/benchmarks/audio.md)
- M5 Pro: Kokoro (CoreML) RTF 0.17; Qwen3-TTS 1.7B RTF 0.79 (4-bit) / 0.85 (8-bit); Qwen3-TTS 0.6B ~0.76 RTF with much higher WER; CosyVoice3 0.5B 4-bit RTF 0.59 — [soniqo.audio](https://soniqo.audio/es/benchmarks)
- VoxCPM2: llama.cpp-omni Metal RTF ~1.76 (Q8_0) on M4 Pro (slower than real time); web demo `--device auto` uses MPS — [VoxCPM](https://github.com/OpenBMB/VoxCPM)
- OmniVoice: `device_map="mps"` with torch 2.8.0 — [OmniVoice](https://github.com/k2-fsa/OmniVoice)
- Chatterbox: `example_for_mac.py` exists; multilingual example lists `"mps"`; Turbo/Nano examples default to `"cuda"`; Nano runs on CPU — [Chatterbox](https://github.com/resemble-ai/chatterbox)
- F5-TTS `speech_edit.py`: device order CUDA → XPU → MPS → CPU; sets `PYTORCH_ENABLE_MPS_FALLBACK=1` — [speech_edit.py](https://raw.githubusercontent.com/SWivid/F5-TTS/main/src/f5_tts/infer/speech_edit.py); README tells Apple Silicon users to install standard torch — [F5-TTS](https://github.com/SWivid/F5-TTS)
- Kyutai: `scripts/tts_mlx.py` with `--quantize 8/4` for Apple silicon — [Kyutai DSM](https://github.com/kyutai-labs/delayed-streams-modeling)
- Seed-VC: Apple Silicon support added 2025-03-03 via `requirements-mac.txt`; real-time GUI needs a Tkinter-enabled Python — [Seed-VC](https://github.com/Plachtaa/seed-vc)
- Coqui fork: macOS wheels since 0.24.2; MPS not mentioned — [idiap](https://github.com/idiap/coqui-ai-TTS)
- Zonos lists macOS as supported; the hybrid model needs NVIDIA 3000+ — [Zonos](https://github.com/Zyphra/Zonos)
- Orpheus: upstream raises "Torch not compiled with CUDA enabled" on M-series; GGUF via LM Studio with Metal recommended — [Codersera guide](https://codersera.com/blog/install-and-run-orpheus-3b-tts-on-macos-a-complete-guide/amp/) (secondary source)
- Dia2 CLI: CUDA if available, else CPU; MPS not mentioned — [Dia2](https://github.com/nari-labs/dia2)
- Qwen3-TTS README examples use `device_map="cuda:0"` with flash-attn — [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS)
- mlx-audio ports: Kokoro, KittenTTS, Qwen3-TTS, Higgs v2/v3, OmniVoice, CSM, Dia (v1), OuteTTS, Spark, Chatterbox (multilingual v3, fp16), Soprano, Ming Omni, KugelAudio, Voxtral, rumik, VoxCPM2, LongCat-AudioDiT, MeloTTS, MOSS-TTS/-Nano — [mlx-audio](https://github.com/Blaizzy/mlx-audio)

### Inferences
- With mlx-audio, Kokoro is far faster than real time. Qwen3-TTS 1.7B and CosyVoice3 run near or just faster than real time on recent M-chips. 2–4B LLM-style TTS models are probably near or slower than real time on PyTorch MPS. That is fine for offline generation in Lift.

### Gaps
- No M-series RTF found for Chatterbox, Dia2, F5-TTS, IndexTTS2, Fish S2 or Higgs on PyTorch MPS.

---

## Q5. CUDA-only dependencies

### Takeaway
Most are shim-able. flash-attn is recommended but not required for Qwen3-TTS. DeepSpeed and the CUDA kernel are optional flags for IndexTTS2. `--cuda-graph` is optional for Dia2. Hard blockers: Step-Audio-EditX (CUDA and Linux required, vLLM/AWQ paths), Zonos hybrid (NVIDIA 3000+, `compile` extra), VoiceCraft (xformers, NVIDIA Docker, MFA/Kaldi via conda), Orpheus upstream (CUDA path, vLLM), Higgs v3 (SGLang/vLLM serving only).

### Cited Findings
- Qwen3-TTS: FlashAttention 2 recommended, examples use `attn_implementation="flash_attention_2"`, not stated as required — [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS)
- IndexTTS2: `use_cuda_kernel`, `use_deepspeed` optional; CUDA Toolkit 12.8+ may be needed on Linux/Windows — [index-tts](https://github.com/index-tts/index-tts)
- Dia2: CUDA 12.8+ drivers listed; `--cuda-graph` optional; CPU fallback — [Dia2](https://github.com/nari-labs/dia2)
- Step-Audio-EditX: NVIDIA CUDA GPU required, Linux tested, PyTorch ≥2.9.1 — [Step-Audio-EditX](https://github.com/stepfun-ai/Step-Audio-EditX)
- Zonos hybrid requires an NVIDIA 3000-series+ and the `compile` extra — [Zonos](https://github.com/Zyphra/Zonos)
- VoiceCraft: xformers 0.0.22, audiocraft pinned, MFA 2.2.17 with Kaldi/openfst via conda, CUDA 11.7 — [VoiceCraft](https://github.com/jasonppy/VoiceCraft)
- VoxCPM pip install lists CUDA ≥12.0 but the demo supports `mps` — [VoxCPM](https://github.com/OpenBMB/VoxCPM)
- CosyVoice: TensorRT-LLM and vLLM optional; Docker uses the NVIDIA runtime — [CosyVoice](https://github.com/FunAudioLLM/CosyVoice)
- PlayDiffusion: needs OPENAI_API_KEY for ASR and word timings by default (a cloud dependency, against Lift's local-only rule); NVIDIA container examples — [PlayDiffusion](https://github.com/playht/PlayDiffusion)

### Inferences
- Lift's existing shim (flash_attn/xformers/triton/bitsandbytes) covers Qwen3-TTS and probably IndexTTS2. VoiceCraft's MFA/conda requirement is a poor fit for non-developer installs.

### Gaps
- requirements.txt files were not individually inspected for Chatterbox, F5-TTS, Fish or IndexTTS. Hidden pins (e.g., `triton`) may exist.

---

## Q6. Quality reputation and project activity

### Takeaway
On the Artificial Analysis Speech Arena (live page, models through Sept 2026), the open-weights order is: Breeze TTS 2 (1222) > Fish S2 Pro (1116) > Step Audio EditX (1096) > Voxtral TTS (1086) > Kokoro 82M (1064) ≈ NVIDIA Magpie-Multilingual 357M (1062) > Maya1 (1046) ≈ OpenAudio S1 Mini (1044) > Higgs V3 (1036) > Chatterbox (1026) > Zonos (1000) > VibeVoice 1.5B (957) ≈ OpenVoice v2 (955) > XTTS v2 (916) > StyleTTS 2 (894) > MetaVoice (848). The proprietary leader, Eleven v4 Turbo, scores 1327. Qwen3-TTS, VoxCPM2, CosyVoice3, IndexTTS2, Dia2 and OmniVoice are not on the AA open list.

### Cited Findings
- AA open-weights ranks and Elo as above; 16 of 96 models are open — [Artificial Analysis](https://artificialanalysis.ai/text-to-speech/leaderboard)
- Breeze TTS 2 released 2026-08-25, 3B; reported Elo varies 1205–1215 in secondary sources — [OrcaRouter](https://www.orcarouter.ai/blog/breeze-tts-2-tops-open-weights-speech-arena), [WaveSpeed](https://wavespeed.ai/blog/commercial-compliance/breeze-tts-2-review/)
- Fish S2 Pro reports top results on EmergentTTS-Eval and Audio Turing Test (vendor-reported) — [BentoML](https://www.bentoml.com/blog/exploring-the-world-of-open-source-text-to-speech-models)
- Activity: Qwen3-TTS released 2026-01-22 — [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS); VoxCPM2 April 2026 — [VoxCPM](https://github.com/OpenBMB/VoxCPM); IndexTTS-2.5 2026-08-10 — [index-tts](https://github.com/index-tts/index-tts); Step-Audio-EditX new model 2026-01-29 — [Step-Audio-EditX](https://github.com/stepfun-ai/Step-Audio-EditX); Fun-CosyVoice3 2025-12 — [CosyVoice](https://github.com/FunAudioLLM/CosyVoice); Vevo2 2026-03-25 — [Amphion](https://github.com/open-mmlab/Amphion); VibeVoice repo now ASR-focused (ASR 2026-01, BitNet 2026-07, Streaming 2026-09) — [VibeVoice](https://github.com/microsoft/VibeVoice); Voxtral TTS March 2026 — [Slator](https://slator.com/mistral-text-to-speech-model/)
- Superseded, withdrawn or abandoned:
  - VibeVoice-TTS code removed (2025-09-05) — [VibeVoice](https://github.com/microsoft/VibeVoice)
  - Seed-VC archived 2025-11-21 — [Seed-VC](https://github.com/Plachtaa/seed-vc)
  - PlayDiffusion archived 2026-07-05 — [PlayDiffusion](https://github.com/playht/PlayDiffusion)
  - Coqui company gone; idiap fork maintained — [idiap](https://github.com/idiap/coqui-ai-TTS)
  - Zonos still at v0.1 — [Zonos](https://github.com/Zyphra/Zonos)
  - Spark-TTS: no dated updates after 2025-03-12 — [Spark-TTS](https://github.com/SparkAudio/Spark-TTS)
  - MegaTTS3: last roadmap item 2025-03-22 — [MegaTTS3](https://github.com/bytedance/MegaTTS3)
  - VoiceCraft: last news 2025-03-15 — [VoiceCraft](https://github.com/jasonppy/VoiceCraft)
  - F5-TTS: last news entry 2025-03-12 (v1) — [F5-TTS](https://github.com/SWivid/F5-TTS)
  - Higgs v2 docs moved to README_V2 (superseded by v3) — [higgs-audio](https://github.com/boson-ai/higgs-audio)
  - OpenAudio S1 replaced by S2 in the fish-speech README — [fish-speech](https://github.com/fishaudio/fish-speech)
  - Dia v1 superseded by Dia2 — [Dia2](https://github.com/nari-labs/dia2)
- Unverified: Tencent AuK/AuK-Flash (Sept 2026) claims TTS + editing + separation under MIT; not reproduced as of Sept 10 — [OrcaRouter](https://www.orcarouter.ai/blog/auk-flash-open-source-release)

### Inferences
- Kokoro has the best quality-per-parameter by far: it ranks above every permissively licensed model except Step Audio EditX.

### Gaps
- I did not fetch the HF TTS Arena V2 or Reddit sentiment this session (tool budget). Community sentiment is therefore not captured beyond leaderboards.

---

## Q7. Editing existing speech audio (added requirement)

### Takeaway
Four kinds of edit exist, each with different inputs:
1. **Word replacement/infilling.** F5-TTS `speech_edit.py` (MPS-ready, but hardcoded inputs and NC weights), VoiceCraft (NC, MFA, stale), PlayDiffusion (archived, OpenAI ASR by default), and CosyEdit (2026, unverified).
2. **Voice conversion of a recording.** Chatterbox `example_vc.py` (MIT), Coqui `tts --source_wav --target_wav` (FreeVC/OpenVoice), Seed-VC `inference.py` (GPL, archived, Mac reqs), RVC (per-voice training, WebUI), Amphion Vevo/Vevo1.5/Vevo2/Metis, and CosyVoice-300M VC.
3. **Emotion/style/paralinguistic/speed edits.** Only Step-Audio-EditX (CUDA only), via `tts_infer.py`.
4. **Continuation.** Dia2 prefix audio, VoxCPM2 "ultimate cloning", CSM context (unverified).

None of the 2026 flagship TTS models (Qwen3-TTS, Higgs v3, Fish S2, Voxtral, OmniVoice, IndexTTS2) offer editing of existing audio.

### Cited Findings
- F5-TTS `speech_edit.py`: inputs are hardcoded module variables, not CLI args:
  - `audio_to_edit` (path)
  - `origin_text` (documentation only, unused)
  - `target_text` (full edited transcript)
  - `parts_to_edit` = list of `[start, end]` seconds (e.g., `[1.42, 2.44], [4.04, 4.9]`)
  - `fix_duration` per span (or `None` to keep original length)
  - model `F5TTS_v1_Base` or `E2TTS_Base`; `nfe_step=32`, `cfg_strength=2.0`
  - output `tests/speech_edit_out.wav`; auto MPS
  - Source: [speech_edit.py](https://raw.githubusercontent.com/SWivid/F5-TTS/main/src/f5_tts/infer/speech_edit.py)
- Step-Audio-EditX inputs per mode — [Step-Audio-EditX](https://github.com/stepfun-ai/Step-Audio-EditX):
  - emotion/style: `--prompt-audio` (source), `--prompt-text` (its transcript), `--edit-type emotion|style`, `--edit-info "fear"|"whisper"...`. Iterative: writes `_edited_iter1.wav`, etc.
  - paralinguistic: source audio and transcript plus `--generated-text` with tags like `[Laughter]`, `[Sigh]`
  - speed: `--edit-info faster|slower|more faster|more slower`
  - denoise/VAD: `--prompt-audio` only
  - clone: source audio, transcript and new text
  - General word replacement is not described; filler-word removal is planned
- VoiceCraft editing via `inference_speech_editing.ipynb`, `inference_speech_editing_scale.py` and Gradio "Edit mode" with a "Transcribe" step; MFA installed for forced alignment — [VoiceCraft](https://github.com/jasonppy/VoiceCraft)
- PlayDiffusion: masks the region to change and diffuses it given updated text plus a speaker embedding from the original; works on real or TTS audio; Gradio only; archived — [PlayDiffusion](https://github.com/playht/PlayDiffusion)
- CosyEdit (Jan 2026): fine-tuned 400M zero-shot TTS for multi-span insertion, deletion and substitution; code linked from HF; usability unconfirmed — [HF CosyEdit](https://huggingface.co/CJY/CosyEdit), [alphaxiv](https://alphaxiv.org/overview/2601.05329v1)
- Chatterbox: `example_vc.py` shipped (voice conversion) — [Chatterbox](https://github.com/resemble-ai/chatterbox)
- Seed-VC VC inputs: `--source` (recording to convert), `--target` (reference voice), `--diffusion-steps`, `--f0-condition` for singing, `--semi-tone-shift`; v2 adds `--convert-style` (accent/emotion) and `--anonymization-only` — [Seed-VC](https://github.com/Plachtaa/seed-vc)
- Coqui: `tts --source_wav --target_wav` with a VC model — [idiap](https://github.com/idiap/coqui-ai-TTS)
- RVC needs ≥10 min of training audio per target voice — [RVC](https://github.com/RVC-Project/Retrieval-based-Voice-Conversion-WebUI)
- Amphion: Vevo (VC, accent conversion), Vevo1.5 (speech/singing editing, VC), Vevo2 (2026-03-25: TTS, SVS, VC, SVC, singing editing, style conversion), Metis (VC, enhancement, target-speaker extraction) — [Amphion](https://github.com/open-mmlab/Amphion)
- CosyVoice: VC listed for CosyVoice-300M (2024/09) — [CosyVoice](https://github.com/FunAudioLLM/CosyVoice)
- Dia2 continuation: `--prefix-speaker-1/-2` audio; Whisper transcribes the prefix — [Dia2](https://github.com/nari-labs/dia2)
- VoxCPM2 "Ultimate cloning": reference audio and its transcript; the model continues from it; no edit mode mentioned — [VoxCPM](https://github.com/OpenBMB/VoxCPM)
- No editing features listed for Higgs v3 [HF](https://huggingface.co/bosonai/higgs-audio-v3-tts-4b), OmniVoice [GitHub](https://github.com/k2-fsa/OmniVoice), Qwen3-TTS [GitHub](https://github.com/QwenLM/Qwen3-TTS), or IndexTTS2 (emotion ref applies to new synthesis) [GitHub](https://github.com/index-tts/index-tts)

### Inferences
- A Lift word-replacement UI should collect: source audio, its transcript (Lift could auto-transcribe with a local ASR such as Whisper and compute word timestamps), the edited transcript, and the time ranges of changed words (derived from the timestamps). The F5-TTS editor needs exactly this but hardcodes it, so Lift needs either a small wrapper script or a pinned fork. Both break the "unmodified upstream CLI" ideal slightly.
- A Lift VC UI needs: source recording plus a reference voice clip (plus optional pitch shift for singing). Chatterbox VC is the cleanest permissive, Mac-friendly option.

### Gaps
- `example_vc.py` arguments for Chatterbox were not inspected (the script exists; whether it takes argv or hardcoded paths is unknown).
- Whether Amphion Vevo1.5 speech editing has a CLI, and its inputs, is unknown (per-model READMEs not opened).
- CosyEdit and Tencent AuK code availability is unverified.

---

## Q8. Ranked shortlist of recipe candidates

### Takeaway
1. **Chatterbox (Multilingual V3 + Turbo + VC)**: the best all-round recipe. It has MIT code and weights, voice cloning, 23 languages, a voice-conversion edit mode, `pip install chatterbox-tts`, a ready `example_for_mac.py` and `"mps"` support, an mlx-audio port, and a built-in watermark for responsible cloning.
2. **Kokoro-82M**: the best small and fast option. It is Apache, #5 open on AA (1064), 20x+ real time on M-series via MLX, 8 languages and 54 voices, and runs on 16 GB Macs trivially. It has no cloning and no editing.
3. **F5-TTS (with `speech_edit.py`)**: the best choice for word replacement in an existing recording, plus solid cloning. The edit script already auto-selects MPS. Caveats: CC-BY-NC weights, and edit inputs are hardcoded, so it needs a thin wrapper.
4. **VoxCPM2** (or Qwen3-TTS): the best permissive multilingual option with voice design. It is Apache with commercial use stated, 30 languages, 48 kHz, has a real CLI (`voxcpm clone/design`), an MPS device option, ~8 GB, and an mlx-audio port. Qwen3-TTS (Apache, 10 languages, VoiceDesign) is the alternative but is Python-API/Gradio-first and has flash-attn defaults.
5. **Dia2**: the best permissive multi-speaker dialogue option. It is Apache, uses `[S1]/[S2]` tags with nonverbals, up to ~2 min, has a real CLI with CPU fallback, and supports prefix continuation. MPS is unverified and output is English only.

All five have a confirmed Mac path. Chatterbox, F5-TTS and VoxCPM2 run on upstream MPS. Kokoro runs on MLX. Dia2 runs on upstream CPU (speed unverified); its predecessor Dia v1 has an MLX port.

Honourable mentions (all Mac-runnable):
- **Seed-VC**: a standalone voice-conversion recipe (CLI, `requirements-mac.txt`), but GPL and archived.
- **OmniVoice**: upstream MPS plus MLX, Apache code, 600+ languages, voice design.
- **Higgs Audio v3 / Voxtral TTS via mlx-audio**: top open quality and 100+ / 9 languages, but non-commercial weights.
- **Kyutai TTS**: official MLX script.

### Cited Findings
- See Q1–Q7 citations: Chatterbox — [GitHub](https://github.com/resemble-ai/chatterbox); Kokoro — [HF](https://huggingface.co/hexgrad/Kokoro-82M), [AA](https://artificialanalysis.ai/text-to-speech/leaderboard), [vllm-mlx](https://vllm-mlx.is-a.dev/benchmarks/audio.md); F5-TTS — [GitHub](https://github.com/SWivid/F5-TTS), [speech_edit.py](https://raw.githubusercontent.com/SWivid/F5-TTS/main/src/f5_tts/infer/speech_edit.py); VoxCPM2 — [GitHub](https://github.com/OpenBMB/VoxCPM); Dia2 — [GitHub](https://github.com/nari-labs/dia2); Seed-VC — [GitHub](https://github.com/Plachtaa/seed-vc)

### Inferences
- Lift's existing "audio" type covers inputs (reference clip, source recording) and output. Editing recipes also need a "transcript" text input and a "time ranges" setting type.

### Gaps
- None of the shortlist has been smoke-tested on an actual M-series Mac in this research. Peak memory and RTF for Chatterbox, F5-TTS, VoxCPM2 and Dia2 on PyTorch MPS should be measured before committing.

### Excluded (no Mac path)
Step-Audio-EditX (CUDA and Linux required) · Fish Audio S2 Pro / OpenAudio S1 (no Mac evidence found) · Breeze TTS 2 (unknown, primary page unreachable) · IndexTTS2/2.5 (no Mac evidence) · MegaTTS3 (no Mac evidence; cloning encoder withheld) · VibeVoice TTS (code removed 2025-09) · VoiceCraft (xformers/MFA/NVIDIA Docker) · PlayDiffusion (archived; OpenAI ASR dependency) · Amphion MaskGCT/Vevo/Vevo2/Metis (NVIDIA Docker; no Mac evidence) · RVC (README lists no macOS path) · Parler-TTS, StyleTTS2, OpenVoice v2, Llasa, Step-Audio TTS, NVIDIA Magpie, Maya1, CosyEdit, Tencent AuK (not researched for Mac this session)
