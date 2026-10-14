"""Small adapters for upstream APIs that have no suitable noninteractive CLI."""
import argparse
from pathlib import Path
import sys


def main():
    p = argparse.ArgumentParser()
    p.add_argument("mode", choices=["fibo-prompt", "prepare-tts", "prepare-sts", "prepare-sdxl", "sdxl", "cogvideo", "deepfilter", "sam-audio", "prepare-open-audio", "open-audio"])
    p.add_argument("--model", required=True)
    p.add_argument("--kind", default="")
    p.add_argument("--base")
    p.add_argument("--output")
    p.add_argument("--audio")
    p.add_argument("--prompt", default="")
    p.add_argument("--width", type=int, default=512)
    p.add_argument("--height", type=int, default=512)
    p.add_argument("--frames", type=int, default=49)
    p.add_argument("--steps", type=int, default=30)
    p.add_argument("--duration", type=float, default=5)
    p.add_argument("--seed", type=int, default=42)
    a = p.parse_args()
    if a.mode == "fibo-prompt":
        import json
        from mflux.models.fibo_vlm.model.fibo_vlm import FiboVLM
        prompt = FiboVLM(model_path=a.model, quantize=4).generate(prompt=a.prompt, seed=a.seed)
        Path(a.output).write_text(json.dumps(json.loads(prompt)))
        return
    if a.mode == "prepare-tts":
        from mlx_audio.tts import load
        model = load(a.model)
        # These upstream codecs/phonemizers are lazy; initialize them while installation can download.
        if a.kind == "kitten":
            model._get_phonemizer()
        elif a.kind == "moss":
            model._ensure_audio_tokenizer()
        elif a.kind == "rumik":
            _ = model.mimi, model.tokenizer
        elif a.kind == "longcat":
            from transformers import AutoTokenizer
            AutoTokenizer.from_pretrained(model.config.text_encoder_model)
        return
    if a.mode in ("prepare-sts", "deepfilter", "sam-audio"):
        from mlx_audio.sts import load
        model = load(a.model)
        if a.kind == "sam" or a.mode == "sam-audio":
            model.text_encoder._lazy_load()
        if a.mode == "prepare-sts":
            return
        if a.mode == "deepfilter":
            model.enhance_file(a.audio, a.output)
        else:
            from mlx_audio.sts.models.sam_audio import save_audio
            result = model.separate(audios=[a.audio], descriptions=[a.prompt])
            save_audio(result.target[0], a.output, sample_rate=model.sample_rate)
            save_audio(result.residual[0], str(Path(a.output).with_name("residual.wav")), sample_rate=model.sample_rate)
        return
    if a.mode in ("prepare-open-audio", "open-audio"):
        sys.path.insert(0, str(Path.cwd()))
        from src.pipeline.pipeline import StableAudioPipeline
        pipe = StableAudioPipeline.from_pretrained(a.model)
        if a.mode == "prepare-open-audio":
            return
        import numpy as np
        import soundfile as sf
        audio = pipe.generate(prompt=a.prompt, negative_prompt="", steps=a.steps,
                              cfg_scale=1.0, seconds_total=a.duration, seed=a.seed, sampler="euler")
        samples = np.asarray(audio[0], dtype=np.float32).T
        if not np.isfinite(samples).all():
            raise RuntimeError("The model returned non-finite audio samples")
        sf.write(a.output, samples, 44100)
        return
    import torch
    if a.mode == "prepare-sdxl":
        from diffusers import StableDiffusionXLPipeline, UNet2DConditionModel, EulerDiscreteScheduler
        from safetensors.torch import load_file
        unet = UNet2DConditionModel.from_config(str(Path(a.base) / "unet"))
        unet.load_state_dict(load_file(str(Path(a.model) / "sdxl_lightning_4step_unet.safetensors")))
        pipe = StableDiffusionXLPipeline.from_pretrained(a.base, unet=unet.to(dtype=torch.float16),
                                                        torch_dtype=torch.float16, variant="fp16", local_files_only=True)
        pipe.scheduler = EulerDiscreteScheduler.from_config(pipe.scheduler.config, timestep_spacing="trailing")
        pipe.save_pretrained(a.output)
        return
    if not torch.backends.mps.is_available():
        raise RuntimeError("This recipe needs PyTorch MPS on Apple Silicon")
    generator = torch.Generator(device="cpu").manual_seed(a.seed)
    if a.mode == "sdxl":
        from diffusers import StableDiffusionXLPipeline
        pipe = StableDiffusionXLPipeline.from_pretrained(a.model, torch_dtype=torch.float16, local_files_only=True).to("mps")
        pipe.enable_attention_slicing()
        pipe.enable_vae_slicing()
        pipe(prompt=a.prompt, width=a.width, height=a.height, num_inference_steps=4,
             guidance_scale=0, generator=generator).images[0].save(a.output)
    else:
        from diffusers import CogVideoXPipeline
        from diffusers.utils import export_to_video
        pipe = CogVideoXPipeline.from_pretrained(a.model, torch_dtype=torch.float16, local_files_only=True).to("mps")
        pipe.vae.enable_slicing()
        pipe.vae.enable_tiling()
        frames = pipe(prompt=a.prompt, num_frames=a.frames, num_inference_steps=a.steps,
                      guidance_scale=6, generator=generator).frames[0]
        export_to_video(frames, a.output, fps=8)


if __name__ == "__main__":
    main()
