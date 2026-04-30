# ComfyUI · Flux 2 · LTX 2.3 · ACE-Step — AEON DGX Spark BF16

> Production-grade ComfyUI distribution engineered exclusively for the
> **NVIDIA DGX Spark (GB10, Blackwell, sm_121a)**. Bleeding-edge ComfyUI
> master + SageAttention v3 compiled for sm_121a + CUDA 13 NVFP4, with
> Flux 2 Dev, LTX 2.3 22B, and ACE-Step v1.5 XL Turbo pre-staged at full
> quality plus NVFP4 hardware-accelerated alternates and abliterated
> text-encoder paths.

```
ghcr.io/aeon-7/comfyui-aeon-spark:bf16-flux2-ltx2.3
ghcr.io/aeon-7/comfyui-aeon-spark:latest
ghcr.io/aeon-7/comfyui-aeon-spark:cu130-sm121a
```

---

## Why this image exists

DGX Spark's **GB10** is a Blackwell datacenter part with **compute
capability 12.1a (sm_121a)** — different from the consumer 5090 (sm_120),
different from Hopper (sm_90), different from the prior-gen consumer
Blackwell (sm_120). Stock ComfyUI containers and stock PyTorch wheels
target older arches and **silently fall back to slower paths or fail to
launch** on Spark.

This image solves that end-to-end:

| Concern | Stock setup | This image |
| --- | --- | --- |
| CUDA toolchain | CUDA 12.x (max sm_120) | **CUDA 13.0.2** — first toolchain that emits sm_121 SASS |
| PyTorch | x86 / cu128 / no sm_121 PTX | **2.9.1+cu130 ARM64**, sm_120 SASS + compute_120 PTX (forward-JITs to sm_121 on first kernel call, then cached) |
| Attention | xformers / FA3 (no sm_121) | **SageAttention v3 compiled from source for `sm_121a` + `sm_121`** — no JIT cost, no fallback to slow SDPA |
| Memory model | discrete-GPU defaults | **Grace-Blackwell unified-memory tuned** — pinned pages off, async offload on, expandable segments |
| Triton | torch.compile crashes on sm_121 | **Triton present, torch.compile explicitly disabled** so dynamo doesn't trip |
| NVFP4 | not exposed | CUTLASS NVFP4 GEMMs via CUDA 13 — `*_fp4_mixed` weights take the accelerated path automatically |
| Manager | manual ltdrdata install | Both **ltdrdata custom node** + the new **`comfyui-manager` pip pkg** with `--enable-manager` |
| Models | bring your own | **36 artifacts auto-pulled on first start (34 named files + 2 huihui-ai abliterated full-LLM snapshots)**: Flux 2, LTX 2.3, ACE-Step + abliterated swap-ins |

---

## What's bundled in the image

### Runtime stack

| Component | Version / source |
| --- | --- |
| Base | `nvidia/cuda:13.0.2-devel-ubuntu24.04` (ARM64) |
| Python | 3.12.3 |
| PyTorch | 2.9.1+cu130 |
| Triton | 3.5.1 (kept available; `torch.compile` disabled by env) |
| SageAttention | v3 main, **compiled with `-gencode arch=compute_121a,code=sm_121a`** |
| ComfyUI | latest `master` (locked in image, upgradable via Manager) |
| ComfyUI-Manager | both ltdrdata node and new `comfyui-manager` pip pkg, `--enable-manager` set by default |
| Diffusers | 0.37.1 |
| Transformers | 5.7.0 |
| HuggingFace Hub | 1.12.0 + `hf-transfer` enabled |
| GGUF runtime | `gguf` >= 0.13 + sentencepiece + protobuf |
| **Total backend nodes registered** | **~1728** (Comfy core + 16 bundled custom node packs) |

### Bundled ComfyUI custom nodes

| Pack | Purpose |
| --- | --- |
| **ComfyUI-Manager** (ltdrdata) | classic node/model manager, pre-seeded into the volume |
| **ComfyUI-LTXVideo** (Lightricks) | official LTX-2 nodes (94 LTX nodes registered) |
| **ComfyUI-GGUF** (city96) | GGUF text encoders + DiTs |
| **ComfyUI_essentials** (cubiq) | image utilities |
| **rgthree-comfy** | workflow ergonomics (48 nodes) |
| **ComfyUI-Custom-Scripts** (pythongosssss) | favorites, autocomplete, etc. |
| **ComfyUI-KJNodes** (kijai) | huge collection incl. GetNode/SetNode virtual links |
| **ComfyUI-Frame-Interpolation** (Fannovel16) | RIFE / FILM video upscaling |
| **ComfyUI-Crystools** | on-canvas perf monitor |
| **ComfyUI-Easy-Use** (yolain) | simplified flux/ltx/sd flows |
| **ComfyUI-RES4LYF** (ClownsharkBatwing) | advanced samplers including `ClownSampler_Beta` family — required by Lightricks's distilled LTX workflow |
| **ComfyUI-VideoHelperSuite** (Kosinkadink) | video I/O nodes |
| **ComfyUI-Ollama** (stavsap) | Ollama LLM-prompting nodes (used by Ancient_Sufi AceStep workflow) |
| **ComfyUI-Detail-Daemon** (Jonseed) | `MultiplySigmas`, `LyingSigmaSampler`, `DetailDaemonGraphSigmasNode` |
| **aeon-server-side-downloads** (in-tree, no backend nodes) | JS click-interceptor — routes "Workflow Overview → Missing Models → Download all / Download" through Manager's server-side install API instead of triggering a browser download. Critical for remote-accessed Sparks. |
| **ComfyUI-PromptRelay** (kijai) | Timeline-based per-second prompt control for video — change descriptions throughout the sequence (used by `10_ltx2.3_prompt_relay`). |

After first start, all 16 packs are editable inside the volume and
ComfyUI-Manager handles installs of any additional nodes.

### Models auto-downloaded on first start (~285 GB)

#### Flux 2 Dev (Black Forest Labs / Comfy-Org pre-split)
| File | Purpose | Size |
| --- | --- | --- |
| `flux2_dev_fp8mixed.safetensors` | DiT (32B params) | 35.5 GB |
| `flux2-vae.safetensors` | VAE | 336 MB |
| `full_encoder_small_decoder.safetensors` | small-decoder VAE used by canonical Flux 2 t2i template | 250 MB |
| `mistral_3_small_flux2_bf16.safetensors` | text encoder, **best quality** | 35.6 GB |
| `mistral_3_small_flux2_fp4_mixed.safetensors` | text encoder, **NVFP4-accelerated** | 12.3 GB |
| `Flux2TurboComfyv2.safetensors` | Turbo LoRA | 2.8 GB |
| `Flux_2-Turbo-LoRA_comfyui.safetensors` | Turbo LoRA, canonical filename | 2.8 GB |

#### LTX 2.3 22B (Lightricks)
| File | Purpose | Size |
| --- | --- | --- |
| `ltx-2.3-22b-dev_transformer_only_bf16.safetensors` | DiT, full quality (transformer-only split) | 42 GB |
| `ltx-2.3-22b-dev_transformer_only_fp8_scaled.safetensors` | DiT, fast alt | 23.5 GB |
| `ltx-2.3-22b-dev-fp8.safetensors` | full FP8 checkpoint (DiT+VAE+CLIP fused, used by canonical T2V/I2V templates) | 29 GB |
| `ltx-2.3_text_projection_bf16.safetensors` | text projection layer | 2.3 GB |
| `LTX23_video_vae_bf16.safetensors` | video VAE | 1.45 GB |
| `LTX23_audio_vae_bf16.safetensors` | audio VAE | 365 MB |
| `taeltx2_3.safetensors` | tiny preview VAE | 23 MB |
| `ltx-2.3-22b-distilled-1.1_lora-dynamic_fro09_avg_rank_111_bf16.safetensors` | dynamic distilled LoRA | 2.7 GB |
| `ltx-2.3-22b-distilled-lora-384.safetensors` | canonical 8-step distilled LoRA | 7.6 GB |
| `ltx-2.3-spatial-upscaler-x2-1.1.safetensors` | spatial upscaler | 1.0 GB |
| `ltx-2.3-temporal-upscaler-x2-1.0.safetensors` | temporal upscaler | 261 MB |

#### Gemma-3 (LTX 2.3 text encoder, Comfy-Org split)
| File | Purpose | Size |
| --- | --- | --- |
| `gemma_3_12B_it.safetensors` | Gemma-3 12B IT, **best quality BF16** | 24.4 GB |
| `gemma_3_12B_it_fp4_mixed.safetensors` | Gemma-3 12B IT, **NVFP4-accelerated** | 9.4 GB |

#### ACE-Step v1.5 (Ancient_Sufi audio-generation workflow)
| File | Purpose | Size |
| --- | --- | --- |
| `acestep_v1.5_xl_turbo_bf16.safetensors` | ACE-Step XL Turbo DiT (BF16) | 9.97 GB |
| `qwen_0.6b_ace15.safetensors` | text encoder A (Qwen 0.6B) | 1.19 GB |
| `qwen_4b_ace15.safetensors` | text encoder B (Qwen 4B) | 8.38 GB |
| `ace_1.5_vae.safetensors` | 1D audio VAE | 337 MB |

#### Abliterated text-encoder paths
| Artifact | How to use | Size |
| --- | --- | --- |
| `gemma-3-12b-it-abliterated_heretic_lora_rank64_bf16.safetensors` | LoRA on top of Gemma-3 BF16/NVFP4 | 628 MB |
| `gemma-3-12b-it-abliterated_lora_rank64_bf16.safetensors` | alternate abliterated LoRA | 628 MB |
| `text_encoders/abliterated/Mistral-Small-3.2-24B-abliterated/` | full HF-format weights — swap-in alt for Flux 2 (`huihui-ai`) | 48 GB |
| `text_encoders/abliterated/Gemma-3-12B-IT-abliterated/` | full HF-format weights — swap-in alt for LTX 2.3 | 24 GB |

Total first-pull is ~285 GB; set `SKIP_ABLITERATED=1` to skip the two
~70 GB snapshots if you only need the LoRA path.

### Default workflows seeded into `user/default/workflows/`

| File | What it does |
| --- | --- |
| `01_flux2_text_to_image.json` | Comfy canonical Flux 2 Dev t2i (subgraph workflow, fp8mixed DiT + Mistral-3 BF16 + small-decoder VAE) |
| `02_ltx2.3_T2V_I2V_distilled.json` | Lightricks's official LTX-2.3 single-stage distilled T2V/I2V (uses `ClownSampler_Beta`, the abliterated Gemma LoRA, the FP8 checkpoint, the distilled-lora-384, and both upscalers) |
| `03_ltx2.3_T2V_two_stage.json` | Lightricks's two-stage T2V (cleaner motion at higher cost) |
| `04_ltx2.3_image_to_video.json` | Comfy canonical LTX-2.3 I2V |
| `05_ltx2.3_first_last_frame_to_video.json` | Comfy canonical LTX-2.3 first-frame/last-frame-to-video |
| `07_ltx2.3_id_lora.json` | Comfy canonical LTX-2.3 with identity-LoRA wiring |
| `08_flux2_klein_9b_text_to_image.json` | Flux 2 Klein 9B variant t2i |
| `09_acestep_ancient_sufi_xl.json` | ACE-Step v1.5 XL Turbo audio generation with Ollama-driven prompt expansion |
| `10_ltx2.3_prompt_relay.json` | LTX 2.3 22B distilled-1.1 fp8 + Kijai's [ComfyUI-PromptRelay](https://github.com/kijai/ComfyUI-PromptRelay) — per-second timeline-based prompt control for video, change descriptions throughout the sequence |

---

## How it's optimized

### The compile-time work that's already been done for you

1. **SageAttention v3 compiled inside the image** with explicit
   `-gencode=arch=compute_121a,code=sm_121a -gencode=arch=compute_121,code=sm_121`.
   That gives Blackwell-datacenter SASS for `_qattn_sm80`, `_qattn_sm89`,
   and `_fused`. **No JIT cost on first generation.**
2. **PyTorch 2.9.1+cu130** ships sm_120 SASS plus compute_120 PTX. On
   Spark the PTX gets JIT-compiled to sm_121a SASS the first time a kernel
   runs, then cached in `~/.nv/ComputeCache`. Forward-compat is the path
   NVIDIA recommends for pre-release silicon.
3. **CUDA 13.0.2 toolchain** in the build image is the first NVCC release
   that knows about sm_121 — CUDA 12.x simply cannot emit it.
4. **All 16 custom node `requirements.txt` resolved at build time**, so
   you don't pay the dependency-resolve tax on every container start.

### The runtime tuning that ships by default

| Knob | Setting | Why |
| --- | --- | --- |
| `--use-sage-attention` | on | fastest sm_121a attention path |
| `--bf16-unet --bf16-vae --bf16-text-enc` | on | Spark's 128 GB unified pool means BF16 is free; NVFP4 weights still take their hardware path automatically when loaded |
| `--disable-pinned-memory` | on | Grace-Blackwell coherent fabric performs *worse* with pinned host pages |
| `--reserve-vram 2.0` | 2 GB | leaves OS scratch on the unified pool — Spark caps utilization at 0.88, see internal note `feedback_dgx_spark_gpu_mem_cap` |
| `--enable-manager` | on | wires the new in-frontend Manager dialog to the `comfyui-manager` pip pkg |
| `--enable-cors-header` | on | lets external clients (mobile UIs, automation) hit the API |
| `TORCH_COMPILE_DISABLE=1` | on | Triton does not yet emit working SASS for sm_121a |
| `CUDA_MODULE_LOADING=EAGER` | on | avoids the lazy-load stall ComfyUI hits on first model swap |
| `PYTORCH_ALLOC_CONF=expandable_segments:True` | on | reduces fragmentation when juggling 35 GB DiTs |
| `CUDA_DEVICE_MAX_COPY_CONNECTIONS=4` | tuned | matches the GB10 copy-engine count |

### Why no FlashAttention

FA2 / FA3 / FA4 don't ship sm_121 kernels (FA4 only does sm_100; FA2/3
stop at sm_90). SageAttention v3 covers the same surface plus quantized
variants the FA family doesn't have. The image deliberately omits
FlashAttention rather than waste size on a wheel that would silently fall
back to PyTorch SDPA.

### Why NVFP4 is automatic

There's no flag to "turn on NVFP4". The weights are FP4 — when ComfyUI's
`CLIPLoader` (or `UNETLoader`) loads `*_fp4_mixed.safetensors`, the
matmul ops dispatch to **CUDA 13's CUTLASS NVFP4 GEMMs**, which on
sm_121a use the 2nd-gen tensor-core FP4 path. No Marlin involved (Marlin
is a Hopper SXM5 code path that mis-fires on GB10 — see internal note
`feedback_dgx_spark_cutlass_nvfp4`).

### Persistent volume layout

```
workspace/                           ← single host-mounted volume
├── models/                          ← 285 GB of pre-staged weights
│   ├── diffusion_models/            ← Flux 2 + LTX 2.3 + ACE-Step DiTs
│   ├── checkpoints/                 ← LTX 2.3 FP8 fused checkpoint
│   ├── text_encoders/               ← Mistral, Gemma, Qwen 0.6B/4B,
│   │   └── abliterated/             ← + huihui-ai abliterated full HF dirs
│   ├── vae/  loras/  latent_upscale_models/
│   ├── controlnet/  upscale_models/  embeddings/  ...
│   └── (all standard ComfyUI subdirs)
├── custom_nodes/                    ← 16 bundled + anything Manager adds
├── output/                          ← generated images, videos, audio
├── input/                           ← reference inputs
├── user/default/workflows/          ← 8 pre-seeded workflows
└── temp/                            ← scratch
```

Wipe the container, rebuild the image, mount the same `workspace/`, and
everything boots in seconds with the same models, settings, Manager-
installed nodes, and saved workflows.

---

## What's *not* included (and why)

- **xformers** — no sm_121 wheel exists; deliberately skipped on ARM64.
- **FlashAttention 2/3/4** — no sm_121 support yet; SageAttention v3
  covers the same surface.
- **bitsandbytes** — depends on FA-style kernels not on sm_121; replace
  with GGUF (already bundled) or NVFP4 weights (already bundled).
- **TensorRT engines** — RT engines aren't portable across compute
  capabilities; building them inside the container would defeat the
  cold-start-ready goal. Run TRT engine builds yourself if you need them.
- **Frontend node editor extras (3D / animation suites)** — install via
  Manager so they live in your volume, not the image.

---

## References

- `feedback_dgx_spark_cutlass_nvfp4` — NVFP4 vs Marlin clarification on Spark.
- `feedback_dgx_spark_gpu_mem_cap` — 0.88 unified-memory utilization cap.
- `feedback_validate_before_public_push` — this image was validated
  (28/28 model files present, 9/9 workflows resolve cleanly, 1725 nodes
  registered, `/system_stats` healthy with all flags applied) before
  being pushed.
- `SparkyUI` reference project — much of the unified-memory tuning here
  follows the same insights.
