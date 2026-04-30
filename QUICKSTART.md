# ComfyUI · AEON DGX Spark — QuickStart

Get a fully-loaded ComfyUI running on your DGX Spark in 3 commands.

---

## Prerequisites

- DGX Spark (GB10 / Blackwell / sm_121a)
- NVIDIA driver ≥ 580 (CUDA 13.0 capable) — verify with `nvidia-smi`
- Docker (`docker --version` ≥ 28) with the `nvidia` runtime registered
- ~350 GB free disk for the model volume (image is 17 GB, models are ~285 GB on first start, leave headroom)
- HuggingFace token in `HF_TOKEN` (free account; needed for Black Forest Labs gated repos)

```bash
# Quick precheck
nvidia-smi | head -3
docker info 2>&1 | grep -i runtime
df -h /
```

---

## 1 · Pull the image

```bash
docker pull ghcr.io/aeon-7/comfyui-aeon-spark:bf16-flux2-ltx2.3
```

Available tags:

| Tag | Use when |
| --- | --- |
| `:latest` | always-current; tracks the most recent canonical release |
| `:bf16-flux2-ltx2.3` | semantic name pinned to this release |
| `:cu130-sm121a` | hardware-pin name; useful for sticking to a known-good build |

---

## 2 · Set up the workspace

The whole ComfyUI workspace — models, custom nodes, outputs, settings — lives in a single host folder you control. Pick a directory with **at least 350 GB free** (the model bundle is ~285 GB).

```bash
mkdir -p ~/comfyui-spark/workspace
cd ~/comfyui-spark
```

Drop a `docker-compose.yml`:

```yaml
services:
  comfyui:
    image: ghcr.io/aeon-7/comfyui-aeon-spark:bf16-flux2-ltx2.3
    container_name: comfyui-spark
    runtime: nvidia
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    ports:
      - "8188:8188"
    environment:
      HF_TOKEN: "${HF_TOKEN:-}"          # gated-repo access
      SKIP_ABLITERATED: "0"              # set to 1 to skip the ~70GB huihui snapshots
      SKIP_MODEL_DOWNLOAD: "0"           # set to 1 to bring your own
    volumes:
      - ./workspace:/workspace/ComfyUI   # single source of truth
    shm_size: "32gb"
    ipc: host
    ulimits:
      memlock: -1
      stack: 67108864
    restart: unless-stopped
```

And a `.env`:

```bash
HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

---

## 3 · Launch

```bash
docker compose up -d
docker compose logs -f comfyui
```

First start downloads ~285 GB of models. At ~95 MB/s on Spark's 10 GbE
expect ~50 minutes; you'll see a `download summary: 35 ok, 0 failed`
line followed by `Launching ComfyUI on port 8188`.

Open the UI:

```
http://<spark-host>:8188
```

If `<spark-host>` is the box itself: `http://localhost:8188`.

---

## What's pre-loaded out of the box

| Workflow (in `Workflows` sidebar) | Model |
| --- | --- |
| **01_flux2_text_to_image** | Flux 2 Dev (BF16 Mistral-3 encoder, fp8mixed DiT) |
| **02_ltx2.3_T2V_I2V_distilled** | LTX 2.3 22B + abliterated Gemma + 8-step distilled LoRA |
| **03_ltx2.3_T2V_two_stage** | LTX 2.3 two-stage (cleaner motion) |
| **04_ltx2.3_image_to_video** | LTX 2.3 image-to-video |
| **05_ltx2.3_first_last_frame_to_video** | LTX 2.3 FLF2V |
| **07_ltx2.3_id_lora** | LTX 2.3 with identity-LoRA wiring |
| **08_flux2_klein_9b_text_to_image** | Flux 2 Klein 9B variant |
| **09_acestep_ancient_sufi_xl** | ACE-Step v1.5 XL Turbo audio with Ollama prompt-expansion |
| **10_ltx2.3_prompt_relay** | LTX 2.3 distilled-1.1 fp8 + Kijai PromptRelay timeline-based per-second prompt control for video |

---

## Optimal settings cheat-sheet

The image already launches with the correct flags — these are listed
here so you understand what knobs to *keep* if you customize the launch.

### The defaults (do not change unless you know why)

```
--use-sage-attention                  # fastest sm_121a attention
--bf16-unet --bf16-vae --bf16-text-enc # full quality, Spark has the RAM
--disable-pinned-memory               # critical for Grace-Blackwell fabric
--reserve-vram 2.0                    # OS scratch within the 0.88 cap
--enable-manager                      # in-frontend Manager dialog
--enable-cors-header                  # external API access
--preview-method auto                 # latent preview during sampling
```

### The environment variables that matter

```
TORCH_COMPILE_DISABLE=1               # MUST stay on — Triton can't emit sm_121a yet
TORCHDYNAMO_DISABLE=1
CUDA_DEVICE_MAX_COPY_CONNECTIONS=4    # matches GB10 copy-engine count
CUDA_MODULE_LOADING=EAGER             # avoids first-model-swap stall
PYTORCH_ALLOC_CONF=expandable_segments:True
HF_HUB_ENABLE_HF_TRANSFER=1           # 3-5× faster HF downloads
```

### Tuning per workflow

| When you want… | Switch to | Why |
| --- | --- | --- |
| **Maximum quality** | leave defaults — the BF16 path is the default | Spark unified memory is plentiful |
| **Maximum throughput** | swap CLIPLoader's encoder file from `*_bf16.safetensors` → `*_fp4_mixed.safetensors` | takes the CUTLASS NVFP4 GEMM path on sm_121a 2nd-gen tensor cores |
| **Fewer-step Flux 2** | drop in `Flux2TurboComfyv2.safetensors` LoRA, set steps to 4–8 | Turbo LoRA is pre-staged |
| **Fast LTX 2.3** | use `02_ltx2.3_T2V_I2V_distilled` workflow as-is — it loads `ltx-2.3-22b-distilled-lora-384` at 8 steps | bundled |
| **No abliteration** (LTX 2.3) | bypass the `LoraLoader` for `gemma-3-12b-it-abliterated_*` in workflow 02 | one click |
| **Audio generation** | open `09_acestep_ancient_sufi_xl` | ACE-Step + Ollama prompt expansion |

---

## Tips & gotchas

### Where everything lives

```
~/comfyui-spark/workspace/
├── models/                  # 285 GB of weights, all pre-staged
│   ├── diffusion_models/    # Flux 2 / LTX 2.3 / ACE-Step DiTs
│   ├── checkpoints/         # LTX 2.3 FP8 fused checkpoint
│   ├── text_encoders/       # Mistral, Gemma, Qwen
│   │   └── abliterated/     # huihui-ai full HF dirs
│   ├── vae/  loras/  latent_upscale_models/
│   └── ... all standard ComfyUI subdirs
├── custom_nodes/            # 16 bundled + anything you install via Manager
├── output/                  # your generated images / videos / audio
├── input/                   # reference inputs
└── user/default/workflows/  # 9 pre-seeded workflows + anything you save
```

### Adding more workflows later

Just drop the `.json` into `~/comfyui-spark/workspace/user/default/workflows/` — no rebuild, no restart. The UI auto-discovers it on the next browser refresh.

### Adding more custom nodes

Use the in-UI Manager (button in the top bar). Installs land in `workspace/custom_nodes/` and survive container recreations.

### Adding more models

Drop files into the appropriate `workspace/models/<subdir>/`. ComfyUI's loaders auto-rescan — refresh the loader's dropdown in the UI.

### Updating ComfyUI itself

```bash
docker compose pull             # grab the latest :latest tag
docker compose up -d            # recreate; volume keeps everything
```

### Skipping the abliterated LLM snapshots (~70 GB saved)

```bash
SKIP_ABLITERATED=1 docker compose up -d
```

The abliterated **LoRA** for the Gemma encoder is still downloaded (only 628 MB) — only the full huihui-ai HF-format weights are skipped.

### Re-running the model download flow

If you want to re-fetch (e.g., after deleting a file):

```bash
rm ~/comfyui-spark/workspace/.models_seeded
docker compose up -d --force-recreate
```

### When Manager says "missing nodes" on a workflow you imported

Click "Install Missing Custom Nodes" — Manager will pull, install requirements, restart ComfyUI. With `--enable-manager` already set you get the new in-frontend dialog (no extra setup needed).

### When ComfyUI fails to launch with OOM

Spark caps GPU utilization at 0.88 of unified memory. The `--reserve-vram 2.0` default leaves enough headroom, but if you stack a 35 GB DiT + 35 GB text encoder + a video VAE you can still overrun. Either:

- swap one encoder to `*_fp4_mixed.safetensors` (cuts ~24 GB)
- lower image/video resolution
- use the FP8 LTX 2.3 DiT instead of BF16 (saves ~18 GB)

### Sharing the GPU with vLLM

The Spark only has one GPU. If you also run `vllm-aeon-ultimate-v2`, stop one before starting the other:

```bash
docker stop vllm-aeon-ultimate-v2 && docker compose up -d   # ComfyUI
# or
docker compose down && docker start vllm-aeon-ultimate-v2   # back to vLLM
```

---

## Troubleshooting one-liners

```bash
# Container healthy?
docker ps --filter "name=comfyui-spark" --format "{{.Status}}"

# /system_stats summary
curl -s http://localhost:8188/system_stats | python3 -m json.tool

# How many nodes are registered?
curl -s http://localhost:8188/object_info | python3 -c "import sys,json; print(len(json.load(sys.stdin)), 'nodes')"

# Are all my workflows clean?  (run on host, hits the live container)
python3 -c "
import json, urllib.request, glob, os, re
ni = json.loads(urllib.request.urlopen('http://localhost:8188/object_info').read())
present = set(ni) | {'MarkdownNote','Note','Reroute','GetNode','SetNode',
                     'Bookmark (rgthree)','Fast Bypasser (rgthree)','Label (rgthree)',
                     'Fast Groups Bypasser (rgthree)','Fast Groups Muter (rgthree)'}
uuid = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}')
for p in sorted(glob.glob(os.path.expanduser('~/comfyui-spark/workspace/user/default/workflows/*.json'))):
    wf = json.load(open(p))
    miss = sorted(t for t in {n['type'] for n in wf['nodes']} if t not in present and not uuid.match(t))
    print(os.path.basename(p), '✓' if not miss else f'⚠ {miss}')
"

# Tail the entrypoint
docker logs -f comfyui-spark | grep -E '\[entrypoint\]|\[downloader\]|To see the GUI'
```

---

## Got more workflows you want bundled by default?

Open an issue (or send a PR adding the `.json` to `workflows/`) — small rebuild and we ship a new tag.
