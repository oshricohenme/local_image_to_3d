# Lift media recipes — 2026-10-13

54 additional recipes: **18 image, 8 music, 18 audio, 10 video**. Together with the four existing recipes, Lift now bundles 58. Each entry implements the specific variant and tasks below; this is not a claim that every variant or feature of each model family is supported.

These are **experimental integrations**. The upstream source, CLI/API contracts and published model-file metadata were inspected. The Lift catalog, command construction, installation lifecycle and export behavior have dry-run tests. No model weights were downloaded, no model was installed, and no inference, timing, memory benchmark or output-quality evaluation was performed for this catalog. Resource numbers in the recipes are provisional admission/storage estimates, not measured requirements. Installation can also use substantial memory while quantizing or converting weights.

## Installation and repository boundary

Only recipe definitions, Lift launchers, shared adapters and tests live in this repository. Each GitHub runtime is cloned by Lift's installer into `<workdir>/models/<recipe-id>/repo` at the recipe's full commit SHA. Python environments, native builds, converted checkpoints and native model caches stay under that model's managed directory. Declared Hugging Face assets go into Lift's shared HF cache. No upstream GitHub checkout or weights are vendored into Lift or its app bundle. `.gitignore` and the app resource-copy rules exclude accidental local checkouts/environments.

Schema 2 adds `prepare`, executed **after dependencies and the recipe have been installed and before the smoke check and installed state**. Preparation downloads declared assets, resolves required lazy codecs/tokenizers, performs conversions and checks expected files. An error keeps the installation failed; cancellation uses the existing process-group handling. Schema 1 recipes keep their current installation behavior. Older Lift versions reject schema 2 instead of skipping preparation.

The media manifest hash is part of the recipe's preparation command and installation digest. Changing an asset or command therefore requires reinstallation. The worker also checks the preparation receipt before starting. Generation uses argument arrays (no shell interpolation of prompts) and sets Hugging Face/Transformers offline flags. Missing, empty, stale or escaping output files fail the job; every declared output pattern must be satisfied. Logs stream through the worker so upstream progress reaches Lift.

System Setup provides Git, uv, native Homebrew, Git LFS and Apple's Metal compiler. A recipe's install automatically adds its own Homebrew tools (`cmake`, `ffmpeg`, `espeak-ng` as applicable), Python dependencies and native build products. Preparation fetches the model assets at **model installation time**. Media recipes reject `download_weights=false` explicitly because preparation requires those assets. Native managed model pulls use their upstream license-acceptance option; Lift's confirmation names the terms and restrictions before running them.

HF preparation reports stages and download logs within installation. It is not a separately pausable entry in Lift's downloads queue; cancel and reinstall can reuse completed HF cache files. The subsequent standard weights verification still runs. Native model bundles are checked by the pinned native downloader and preparation's required-file checks.

## Runtime evidence and requirements

| Runtime | Source inspected | Installation work | Remaining validation |
|---|---|---|---|
| MFLUX | [Upstream model implementations and CLI](https://github.com/mflux-community/mflux) | Install pinned source; fetch HF components; save/quantize applicable checkpoints. FIBO additionally prepares its VLM; Lens prepares its separate encoder and VAE. | End-to-end Metal inference, memory and image quality |
| stable-diffusion.cpp | [Upstream supported models and CLI](https://github.com/leejet/stable-diffusion.cpp) | CMake Metal build; download selected weights/encoders/VAEs; convert SeFi; install FFmpeg. Video AVI output is converted to MP4. | Per-model Metal operator coverage and practical video memory |
| mlx-audio | [Upstream speech and separation models](https://github.com/Blaizzy/mlx-audio) | Install TTS/STS extras; fetch model assets; initialize lazy tokenizers/codecs. Kitten installs espeak-ng and phonemizer-fork. | All model load/generation paths on hardware, voice quality and language coverage |
| mere.run | [Native runtime and managed model catalog](https://github.com/sawfwair/mere-run) | Hydrate Git LFS; Swift release build and MLX metallib; explicit model pulls into Lift-owned native caches; FFmpeg. | Native build/install on a clean Mac, all generation modes and memory limits |
| mlx-audiocraft | [MusicGen/AudioGen port](https://github.com/theashishmaurya/mlx-audiocraft) | Install port and Transformers <5; load the local pinned checkpoint and prepare its text encoder/codec caches. | Generation quality and dependency compatibility |
| Stable Audio 3 MLX | [Official MLX implementation](https://github.com/Stability-AI/stable-audio-3/tree/main/optimized/mlx) | Fetch DiT, encoder, decoder and bundled T5Gemma/tokenizer NPZs; install official requirements and FFmpeg. | Text and variation inference |
| HeartMuLa MLX | [Port and converter](https://github.com/Acelogic/heartlib-mlx) | Convert HeartMuLa and HeartCodec separately; fetch tokenizer from HeartMuLaGen. | Converter compatibility and vocal/audio quality |
| Stable Audio Open MLX | [Community port](https://github.com/sandst1/stable-audio-mlx) | Convert Small checkpoint; provide pinned Open 1.0 T5 encoder/tokenizer; initialize pipeline. | Converter and waveform quality |
| Diffusers/MPS | [SDXL-Lightning model card](https://huggingface.co/ByteDance/SDXL-Lightning), [CogVideoX-2B card](https://huggingface.co/zai-org/CogVideoX-2b) | Install pinned Diffusers/Transformers; prepare Lightning's 4-step UNet with SDXL base or load CogVideoX locally; FFmpeg for video. | MPS inference, especially large video tensor limits |

Source commits and explicitly declared HF snapshots are pinned in each recipe. Native checkpoints follow the pinned runtime's catalog. Some upstream lazy auxiliary loaders and transitive package dependencies still use upstream defaults; this is not a fully locked, reproducible dependency environment. Installation logs and the preparation receipt retain the resolved local asset paths.

## Implemented catalog

The recipe link contains the exact source commit, HF revisions, selected files, dependencies, typed inputs, settings, attribution and preparation hash. The model-card link provides the primary published use terms where available. Native entries link to their pinned runtime's model-source inventory.

| Recipe / variant | Category | Implemented tasks | Mac runtime | Model/source | License label |
|---|---|---|---|---|---|
| [ACE Step 1.5](../dev-recipes/ace-step15/recipe.yaml) | music | generate song, cover song | mere | [Source](https://github.com/sawfwair/mere-run/blob/01feae347b640f1c9fa8bf8e7dfbf782497d2706/docs/model-sources.md) | Apache-2.0 |
| [Anima](../dev-recipes/anima/recipe.yaml) | image | text to image | sdcpp | [Source](https://huggingface.co/circlestone-labs/Anima) | LicenseRef-Anima |
| [AudioGen Medium](../dev-recipes/audiogen/recipe.yaml) | audio | text to sound | craft | [Source](https://huggingface.co/facebook/audiogen-medium) | CC-BY-NC-4.0 |
| [Boogu Image Turbo](../dev-recipes/boogu-image-turbo/recipe.yaml) | image | text to image | mflux | [Source](https://huggingface.co/Boogu/Boogu-Image-0.1-Turbo) | Apache-2.0 |
| [Chroma1 HD](../dev-recipes/chroma1-hd/recipe.yaml) | image | text to image | sdcpp | [Source](https://huggingface.co/lodestones/Chroma1-HD) | Apache-2.0 |
| [CogVideoX 2B](../dev-recipes/cogvideox2b/recipe.yaml) | video | text to video | diffusers | [Source](https://huggingface.co/zai-org/CogVideoX-2b) | Apache-2.0 |
| [Cosmos3 Edge](../dev-recipes/cosmos3-edge/recipe.yaml) | video | image to video | mere | [Source](https://github.com/sawfwair/mere-run/blob/01feae347b640f1c9fa8bf8e7dfbf782497d2706/docs/model-sources.md) | OpenMDW-1.1 |
| [CSM 1B](../dev-recipes/csm-1b/recipe.yaml) | audio | voice clone | audio | [Source](https://huggingface.co/mlx-community/csm-1b) | Apache-2.0 |
| [DeepFilterNet 3](../dev-recipes/deepfilternet3/recipe.yaml) | audio | enhance audio | audio | [Source](https://huggingface.co/mlx-community/DeepFilterNet-mlx) | MIT |
| [DialogueSidon](../dev-recipes/dialogue-sidon/recipe.yaml) | audio | separate audio | audio | [Source](https://huggingface.co/mlx-community/DialogueSidon-bf16) | CC-BY-NC-4.0 |
| [FIBO](../dev-recipes/fibo/recipe.yaml) | image | text to image | mflux | [Source](https://huggingface.co/briaai/FIBO) | LicenseRef-BRIA-FIBO |
| [FLUX.2 Klein 4B](../dev-recipes/flux2-klein-4b/recipe.yaml) | image | text to image, edit image | mflux | [Source](https://huggingface.co/black-forest-labs/FLUX.2-klein-4B) | Apache-2.0 |
| [HeartMuLa 3B](../dev-recipes/heartmula3b/recipe.yaml) | music | generate song | heart | [Source](https://huggingface.co/HeartMuLa/HeartMuLa-oss-3B) | Apache-2.0 |
| [HunyuanVideo 1.5](../dev-recipes/hunyuan-video15/recipe.yaml) | video | text to video | sdcpp | [Source](https://huggingface.co/Comfy-Org/HunyuanVideo_1.5_repackaged) | LicenseRef-HunyuanVideo |
| [Ideogram 4](../dev-recipes/ideogram4/recipe.yaml) | image | text to image | mflux | [Source](https://huggingface.co/ideogram-ai/ideogram-4-fp8) | LicenseRef-Ideogram-NonCommercial |
| [Iris 3B](../dev-recipes/iris-3b/recipe.yaml) | image | text to image | sdcpp | [Source](https://huggingface.co/speridlabs/iris-3b) | Apache-2.0 |
| [KittenTTS Mini](../dev-recipes/kitten-tts/recipe.yaml) | audio | text to speech | audio | [Source](https://huggingface.co/mlx-community/kitten-tts-mini-0.8) | Apache-2.0 |
| [Lens Turbo](../dev-recipes/lens-turbo/recipe.yaml) | image | text to image | mflux | [Source](https://huggingface.co/Comfy-Org/Lens) | NOASSERTION |
| [LingBot Video 1.3B](../dev-recipes/lingbot-video/recipe.yaml) | video | text to video, image to video | sdcpp | [Source](https://huggingface.co/robbyant/lingbot-video-dense-1.3b) | Apache-2.0 |
| [LLaDA Image Turbo](../dev-recipes/llada-image-turbo/recipe.yaml) | image | text to image, edit image | sdcpp | [Source](https://huggingface.co/fszontagh/LLaDA-Image-Turbo-GGUF) | Apache-2.0 |
| [LongCat AudioDiT](../dev-recipes/longcat-audiodit/recipe.yaml) | audio | text to speech, voice clone | audio | [Source](https://huggingface.co/mlx-community/LongCat-AudioDiT-1B-bf16) | MIT |
| [LongCat Image + Edit Turbo](../dev-recipes/longcat-image/recipe.yaml) | image | text to image, edit image | sdcpp | [Source](https://huggingface.co/Comfy-Org/LongCat-Image) | Apache-2.0 |
| [LTX 2.3 Video](../dev-recipes/ltx-video/recipe.yaml) | video | text to video, image to video | mere | [Source](https://github.com/sawfwair/mere-run/blob/01feae347b640f1c9fa8bf8e7dfbf782497d2706/docs/model-sources.md) | LicenseRef-LTX |
| [Magenta RealTime 2](../dev-recipes/magenta-realtime2/recipe.yaml) | music | instrumental music | mere | [Source](https://github.com/sawfwair/mere-run/blob/01feae347b640f1c9fa8bf8e7dfbf782497d2706/docs/model-sources.md) | CC-BY-4.0 |
| [Ming Image Design](../dev-recipes/ming-image-design/recipe.yaml) | image | text to image | mflux | [Source](https://huggingface.co/inclusionAI/Ming-Image-0.1-Design) | MIT |
| [MiniMax Music 3](../dev-recipes/minimax-music3/recipe.yaml) | music | generate song | mere | [Source](https://github.com/sawfwair/mere-run/blob/01feae347b640f1c9fa8bf8e7dfbf782497d2706/docs/model-sources.md) | LicenseRef-MiniMax-Music3 |
| [MiniT2I B16](../dev-recipes/minit2i/recipe.yaml) | image | text to image | sdcpp | [Source](https://huggingface.co/MiniT2I/MiniT2I) | MIT |
| [MMAudio Large 44k v2](../dev-recipes/mmaudio/recipe.yaml) | audio | text to sound, video to sound | mere | [Source](https://github.com/sawfwair/mere-run/blob/01feae347b640f1c9fa8bf8e7dfbf782497d2706/docs/model-sources.md) | CC-BY-NC-4.0 |
| [MOSS TTS Nano](../dev-recipes/moss-tts-nano/recipe.yaml) | audio | text to speech, voice clone | audio | [Source](https://huggingface.co/mlx-community/MOSS-TTS-Nano-100M) | Apache-2.0 |
| [MOSS TTS 1.5](../dev-recipes/moss-tts15/recipe.yaml) | audio | text to speech, voice clone | audio | [Source](https://huggingface.co/OpenMOSS-Team/MOSS-TTS-v1.5) | Apache-2.0 |
| [MusicGen Small](../dev-recipes/musicgen/recipe.yaml) | music | text to music | craft | [Source](https://huggingface.co/facebook/musicgen-small) | CC-BY-NC-4.0 |
| [OmniVoice](../dev-recipes/omnivoice/recipe.yaml) | audio | text to speech, voice clone | audio | [Source](https://huggingface.co/mlx-community/OmniVoice-bf16) | NOASSERTION |
| [Ovis Image](../dev-recipes/ovis-image/recipe.yaml) | image | text to image | sdcpp | [Source](https://huggingface.co/Comfy-Org/Ovis-Image) | Apache-2.0 |
| [Qwen3 TTS CustomVoice](../dev-recipes/qwen3-tts/recipe.yaml) | audio | text to speech | audio | [Source](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit) | Apache-2.0 |
| [rumik oss 1](../dev-recipes/rumik-oss/recipe.yaml) | audio | text to speech | audio | [Source](https://huggingface.co/rumik-ai/rumik-oss-1-mlx-4bit) | CC-BY-NC-4.0 |
| [SAM Audio Large](../dev-recipes/sam-audio/recipe.yaml) | audio | separate audio | audio | [Source](https://huggingface.co/mlx-community/sam-audio-large) | LicenseRef-SAM-Audio |
| [SCAIL 2](../dev-recipes/scail2/recipe.yaml) | video | animate subject | mere | [Source](https://github.com/sawfwair/mere-run/blob/01feae347b640f1c9fa8bf8e7dfbf782497d2706/docs/model-sources.md) | LicenseRef-SCAIL |
| [Stable Diffusion 3.5 Medium](../dev-recipes/sd35-medium/recipe.yaml) | image | text to image | sdcpp | [Source](https://huggingface.co/stabilityai/stable-diffusion-3.5-medium) | LicenseRef-Stability-Community |
| [SDXL Lightning](../dev-recipes/sdxl-lightning/recipe.yaml) | image | text to image | diffusers | [Source](https://huggingface.co/ByteDance/SDXL-Lightning) | OpenRAIL++ |
| [SeFi Image 1B Turbo](../dev-recipes/sefi-image/recipe.yaml) | image | text to image | sdcpp | [Source](https://huggingface.co/SeFi-Image/SeFi-Image-1B-turbo) | CC-BY-NC-4.0 |
| [SenseNova U1.5](../dev-recipes/sensenova-u15/recipe.yaml) | image | text to image | sdcpp | [Source](https://huggingface.co/sensenova/SenseNova-U1.5-8B-MoT) | Apache-2.0 |
| [Soprano 1.1](../dev-recipes/soprano/recipe.yaml) | audio | text to speech | audio | [Source](https://huggingface.co/mlx-community/Soprano-1.1-80M-bf16) | NOASSERTION |
| [Spark TTS](../dev-recipes/spark-tts/recipe.yaml) | audio | text to speech, voice clone | audio | [Source](https://huggingface.co/mlx-community/Spark-TTS-0.5B-bf16) | CC-BY-NC-SA-4.0 |
| [Stable Audio Open Small](../dev-recipes/stable-audio-open-small/recipe.yaml) | audio | text to sound | saopen | [Source](https://huggingface.co/stabilityai/stable-audio-open-small) | LicenseRef-Stability-Community |
| [Stable Audio 3 Medium](../dev-recipes/stable-audio3-medium/recipe.yaml) | music | text to music, audio variation | sa3 | [Source](https://huggingface.co/stabilityai/stable-audio-3-optimized) | LicenseRef-Stability-Community |
| [Stable Audio 3 Small Music](../dev-recipes/stable-audio3-music/recipe.yaml) | music | text to music, audio variation | sa3 | [Source](https://huggingface.co/stabilityai/stable-audio-3-optimized) | LicenseRef-Stability-Community |
| [Stable Audio 3 Small SFX](../dev-recipes/stable-audio3-sfx/recipe.yaml) | audio | text to sound, audio variation | sa3 | [Source](https://huggingface.co/stabilityai/stable-audio-3-optimized) | LicenseRef-Stability-Community |
| [Wan 2.1 T2V 1.3B](../dev-recipes/wan21/recipe.yaml) | video | text to video | sdcpp | [Source](https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged) | Apache-2.0 |
| [Wan 2.1 VACE 1.3B](../dev-recipes/wan21-vace/recipe.yaml) | video | text to video, image to video | sdcpp | [Source](https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged) | Apache-2.0 |
| [Wan 2.2 TI2V 5B](../dev-recipes/wan22/recipe.yaml) | video | text to video, image to video | sdcpp | [Source](https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged) | Apache-2.0 |
| [Wan 2.2 Speech to Video](../dev-recipes/wan22-s2v/recipe.yaml) | video | speech to video | sdcpp | [Source](https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged) | Apache-2.0 |
| [Woosh DFlow](../dev-recipes/woosh/recipe.yaml) | audio | text to sound | mere | [Source](https://github.com/sawfwair/mere-run/blob/01feae347b640f1c9fa8bf8e7dfbf782497d2706/docs/model-sources.md) | CC-BY-NC-4.0 |
| [YuE2 3B](../dev-recipes/yue2/recipe.yaml) | music | generate song | mere | [Source](https://github.com/sawfwair/mere-run/blob/01feae347b640f1c9fa8bf8e7dfbf782497d2706/docs/model-sources.md) | CC-BY-NC-4.0 |
| [Z Image Turbo](../dev-recipes/z-image-turbo/recipe.yaml) | image | text to image | mflux | [Source](https://huggingface.co/Tongyi-MAI/Z-Image-Turbo) | Apache-2.0 |

## Boundaries and use notes

- The original research report is retained in `reports/Lift media generation recipe candidates.md`; its broader editing roadmap is not a statement that every described editor is implemented here.
- FIBO is text-to-image in this catalog. FLUX.2 Klein and LongCat expose image editing; ACE-Step exposes audio covers; Stable Audio 3 exposes audio variation. Native video entries provide the listed generation/animation tasks. Full mask painting, timelines, retake/extend controls and additional precision/runtime variants are outside this change.
- SCAIL 2 requires both a reference image mask and a driving-video mask using its upstream seven-color convention. SAM Audio returns the target and residual; DialogueSidon returns two speaker stems. Lift preserves all these files during original-format export, including cleanup after a verified copy.
- Lens uses a Comfy-Org mirror of withdrawn original weights. Its provenance/use terms remain unresolved; it is labeled `NOASSERTION`. Several other models have custom or noncommercial terms. A license label is not legal clearance; review the linked model cards and component restrictions before use.
- Voice-conditioning tasks require the reference audio and its transcript. The generic form exposes these as typed recipe inputs; there is no new recording or timeline editor.
- The native library now groups image, music, audio and video recipes. The existing image/audio/video viewers handle results. Media jobs default to **Original files** export; 3D jobs retain mesh conversion formats.
- Dry-run tests cannot prove numerical correctness, fit in RAM, successful gated access or offline cache completeness. A real install followed by a short generation for each task is the next acceptance gate; no such result is claimed here.

## Verification

Run `swift test` for the installer, catalog, UI-model, export and HTTP/MCP contracts. Run the dependency-free adapter tests with:

```sh
PYTHONPATH=dev-recipes/shared/media/src python3 -m unittest discover -s dev-recipes/shared/media/tests -v
```

The same adapter tests are included in CI. The native app build checks that all recipes and the shared package are bundled while checkout/environment directories are excluded. No download or inference test is hidden inside this test suite.

The companion [CSV](media-recipes.csv) is suitable for filtering the catalog and reviewing estimates.

When editing a recipe's `files/media.json`, recompute its SHA-256 and replace the `--expected` value in `recipe.yaml`'s `prepare` command. This intentionally invalidates old installation receipts. Keep the manifest's asset list, `weights` and attribution synchronized. `launcher.py` delegates to `dev-recipes/shared/media`; no downloaded upstream code belongs in a recipe folder.
