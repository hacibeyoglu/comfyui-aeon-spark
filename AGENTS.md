# AGENTS.md

> Deployment guide for AI agents — how to install and validate this image on a
> NVIDIA DGX Spark host. **Follow the sections in order.** Every command is
> copy-pasteable. Stop conditions are marked **STOP →**.

---

## 0 · Identity

**Repository:** `AEON-7/comfyui-aeon-spark`
**Image:** `ghcr.io/aeon-7/comfyui-aeon-spark:latest` (slim, 17 GB — published)
**Alternate:** `:full` (277 GB, every model pre-baked) — **buildable locally via `Dockerfile.full`; not currently on GHCR.** If the user wants the full variant, follow the "Building `:full` locally" section in README.md.
**Purpose:** ComfyUI workstation pre-loaded with Flux 2 Dev, LTX 2.3 22B, and ACE-Step v1.5 XL Turbo, optimized for DGX Spark (GB10 / Blackwell / **sm_121a**).
**You are deploying onto:** a single DGX Spark host with Docker installed.
**Approximate disk needed:**
- **Slim** (default): **350 GB** (17 GB image + 285 GB workspace + headroom).
- **Full** (pre-baked): **300 GB** (277 GB image + ~20 GB workspace headroom).

**Approximate time to first generation:**
- **Slim**: **~50 minutes** (image pull ~5 min + model download ~45 min — bound by HF bandwidth).
- **Full**: **pull-time + ~10 sec** (no downloads on first start; pull time depends on your connection and image size).

Pick **slim** for normal deployments. Pick **full** when:
- The Spark is air-gapped or has restricted egress.
- You don't have / don't want to provide an HF token.
- You want a sealed, reproducible deployment that's identical on every host (every model byte pinned to the image digest).

---

## 1 · Pre-flight (verify hardware before doing anything)

Run **all** of these. If any fail, **STOP →** and report the failure to the user. **Do not work around them.**

```bash
# Must report "GB10" — anything else means this is not a DGX Spark
nvidia-smi --query-gpu=name --format=csv,noheader

# Must report compute capability 12.1 or higher
nvidia-smi --query-gpu=compute_cap --format=csv,noheader

# Must report CUDA Version 13.x (driver-side support; the image carries its own toolkit)
nvidia-smi | head -3 | grep -oE "CUDA Version: [0-9.]+"

# Must report aarch64
uname -m

# Docker must support the nvidia runtime
docker info 2>&1 | grep -E "Runtimes:.*nvidia" || echo "MISSING_NVIDIA_RUNTIME"
docker compose version 2>&1 | grep -q "Docker Compose" || echo "MISSING_DOCKER_COMPOSE"

# Must have ≥ 350 GB free on the chosen host path (default below: $HOME)
df -BG --output=avail "$HOME" | tail -1
```

**Acceptance criteria:**
- GPU name = `NVIDIA GB10`
- Compute cap = `12.1` (sm_121 family)
- CUDA Version ≥ `13.0`
- arch = `aarch64`
- nvidia runtime present
- Free space ≥ 350 GB

If running on a non-Spark Blackwell box (e.g. RTX 5090), see §10 *Cross-platform fallback*.

---

## 2 · Required inputs from the user (ask if missing)

Before running anything that consumes time/bandwidth, confirm:

1. **HuggingFace token** with read access — needed for Black Forest Labs gated repos (Flux 2). Form: `hf_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`.
   Ask the user: *"Please provide your HuggingFace access token (read scope is enough; needed for Flux 2's gated repo)."*
2. **Workspace path on the host.** Default: `~/comfyui-spark`. If the user has another mount, ask.
3. **Whether to skip abliterated full-LLM snapshots** (~70 GB saved). Default: keep them. Ask only if disk is tight.
4. **Public port** for the UI. Default: `8188`. Only ask if there's a conflict.

**Do not invent a token.** **Do not skip the abliterated snapshots without asking** — they're what makes the "abliterated" path work.

---

## 3 · One-shot deployment

Plug the user's values into the variables below and run as a single block.

```bash
# ── parameters ──────────────────────────────────────────────────────────────
IMAGE_TAG="${IMAGE_TAG:-latest}"             # `latest` (slim) or `full` (pre-baked)
WORKSPACE="${WORKSPACE:-$HOME/comfyui-spark}"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"
SKIP_ABLITERATED="${SKIP_ABLITERATED:-0}"   # set to 1 to skip ~70 GB
# HF_TOKEN is required for `latest`/slim (downloads gated repos at runtime).
# It is OPTIONAL for `full` (everything pre-baked).  Pass empty string if `full`.
HF_TOKEN="${HF_TOKEN:-}"
if [ "$IMAGE_TAG" = "latest" ] || [ "$IMAGE_TAG" = "slim" ] || [ "$IMAGE_TAG" = "bf16-flux2-ltx2.3" ] || [ "$IMAGE_TAG" = "cu130-sm121a" ]; then
    : "${HF_TOKEN:?must be set when using slim tag; ask user for hf_... read token}"
fi
# ────────────────────────────────────────────────────────────────────────────

mkdir -p "$WORKSPACE/workspace"
cd "$WORKSPACE"

# Drop the .env (used by docker compose)
cat > .env <<EOF
HF_TOKEN=$HF_TOKEN
COMFYUI_PORT=$COMFYUI_PORT
SKIP_ABLITERATED=$SKIP_ABLITERATED
EOF
chmod 600 .env

# Drop the docker-compose.yml
cat > docker-compose.yml <<'YAML'
services:
  comfyui:
    image: ghcr.io/aeon-7/comfyui-aeon-spark:${IMAGE_TAG:-latest}
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
      - "${COMFYUI_PORT:-8188}:8188"
    environment:
      HF_TOKEN: "${HF_TOKEN:-}"
      SKIP_ABLITERATED: "${SKIP_ABLITERATED:-0}"
    volumes:
      - ./workspace:/workspace/ComfyUI
    shm_size: "32gb"
    ipc: host
    ulimits:
      memlock: -1
      stack: 67108864
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:8188/system_stats >/dev/null || exit 1"]
      interval: 30s
      timeout: 10s
      start_period: 600s
      retries: 5
YAML

# Pull and start
docker pull ghcr.io/aeon-7/comfyui-aeon-spark:latest
docker compose up -d

echo "Container started. Tailing logs — Ctrl-C to detach."
docker compose logs -f comfyui
```

**Expected log signals during first start, in order:**

1. `comfyui-ollama` becomes healthy first (auto-pulls `gemma3:4b` ~3 GB)
2. `[entrypoint] ComfyUI for DGX Spark (sm_121a, CUDA 13)`
3. `[entrypoint] Sage : installed @ /opt/venv/...`
4. `[entrypoint] Manager: pip pkg present @ /opt/venv/...`
5. `[entrypoint] Seeding workflow: 01_flux2_text_to_image.json` (×8)
6. `[entrypoint] Downloading models — this can take a while on first start...`
7. `[downloader] ⤓` then `[downloader] ✓ done:` lines (×33 named files, then ×2 snapshots)
8. `[downloader] download summary: 35 ok, [N] failed` (1 failure expected if BFL Klein license not accepted)
9. `[entrypoint] Launching ComfyUI on port 8188`
10. `Background asset scan initiated for models, input, output` (server-side missing-model detection enabled)
11. `Starting server` / `To see the GUI go to: http://0.0.0.0:8188`

If the user wants the agent to wait without holding their terminal, use a polling background job rather than `docker compose logs -f`:

```bash
until curl -fsS -m 3 "http://127.0.0.1:${COMFYUI_PORT:-8188}/system_stats" >/dev/null 2>&1; do sleep 30; done
echo "ComfyUI is up at http://<host>:${COMFYUI_PORT:-8188}"
```

---

## 4 · Post-deploy validation

Run **all** checks. **STOP →** and report the failure if any check fails.

```bash
PORT="${COMFYUI_PORT:-8188}"

# 4.1 Container is healthy
docker ps --filter "name=comfyui-spark" --format "{{.Names}} {{.Status}}" | grep -q "healthy\|Up"

# 4.2 ComfyUI is serving
curl -fsS "http://127.0.0.1:$PORT/system_stats" >/dev/null

# 4.3 GPU is visible from inside the container
curl -fsS "http://127.0.0.1:$PORT/system_stats" | python3 -c "
import sys, json
d = json.load(sys.stdin)
dev = d['devices'][0]
assert dev['type'] == 'cuda', f'GPU not visible: {dev}'
assert dev['vram_total'] > 100*2**30, f'VRAM too low: {dev[\"vram_total\"]/2**30:.0f} GiB'
print(f'OK: {dev[\"name\"]}  vram_total={dev[\"vram_total\"]/2**30:.1f} GiB')
"

# 4.4 SageAttention + Manager + correct flags
curl -fsS "http://127.0.0.1:$PORT/system_stats" | python3 -c "
import sys, json
argv = json.load(sys.stdin)['system']['argv']
required = ['--use-sage-attention', '--bf16-unet', '--disable-pinned-memory', '--enable-manager']
missing = [f for f in required if f not in argv]
assert not missing, f'Missing flags: {missing}'
print('OK: all critical flags present')
"

# 4.5 All 28 model files landed
docker exec comfyui-spark bash -c "find /workspace/ComfyUI/models -type f \\( -name '*.safetensors' -o -name '*.ckpt' \\) ! -path '*/.cache/*' | wc -l" \
  | (read n; [ "$n" -ge 28 ] && echo "OK: $n model files present" || echo "FAIL: only $n model files")

# 4.6 Every seeded workflow's nodes resolve
python3 <<'PY'
import json, urllib.request, glob, os, re, sys
PORT = os.environ.get('COMFYUI_PORT', '8188')
ni = json.loads(urllib.request.urlopen(f'http://127.0.0.1:{PORT}/object_info', timeout=15).read())
present = set(ni) | {'MarkdownNote','Note','Reroute','GetNode','SetNode',
                     'Bookmark (rgthree)','Fast Bypasser (rgthree)','Label (rgthree)',
                     'Fast Groups Bypasser (rgthree)','Fast Groups Muter (rgthree)'}
uuid = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}')
ws = os.path.expanduser('${WORKSPACE:-$HOME/comfyui-spark}/workspace/user/default/workflows/')
ws = os.path.expandvars(ws)
ok = bad = 0
for p in sorted(glob.glob(ws + '*.json')):
    types = {n['type'] for n in json.load(open(p))['nodes']}
    miss = sorted(t for t in types if t not in present and not uuid.match(t))
    print(f"  {os.path.basename(p)}: {'✓' if not miss else '⚠ ' + ','.join(miss)}")
    ok += not miss; bad += bool(miss)
print(f'\n{ok} clean, {bad} with missing nodes')
sys.exit(0 if bad == 0 else 1)
PY
```

If 4.6 reports missing nodes, install them via the in-UI Manager (it's already wired) — do **not** try to install custom nodes manually with pip. **STOP →** and ask the user before running pip in the container.

---

## 5 · What you've delivered

- ComfyUI listening on `http://<spark-host>:${COMFYUI_PORT:-8188}`
- 8 pre-loaded workflows in the **Workflows** sidebar:
  | Open this | To do this |
  | --- | --- |
  | `01_flux2_text_to_image` | Flux 2 Dev image generation |
  | `02_ltx2.3_T2V_I2V_distilled` | LTX 2.3 video, 8-step, abliterated Gemma |
  | `03_ltx2.3_T2V_two_stage` | LTX 2.3 video, two-stage, cleaner motion |
  | `04_ltx2.3_image_to_video` | LTX 2.3 i2v |
  | `05_ltx2.3_first_last_frame_to_video` | LTX 2.3 flf2v |
  | `07_ltx2.3_id_lora` | LTX 2.3 with identity LoRA |
  | `08_flux2_klein_9b_text_to_image` | Flux 2 Klein 9B variant |
  | `09_acestep_ancient_sufi_xl` | ACE-Step audio (with Ollama prompt expansion) |
- ComfyUI-Manager wired and clickable in the top bar (for installing additional nodes).
- Persistent workspace at `$WORKSPACE/workspace/` — survives container recreations.

---

## 6 · Common failure patterns and exact fixes

| Symptom | Likely cause | Exact fix |
| --- | --- | --- |
| `docker pull` returns 401/403 | image visibility was reverted to private | Tell the user to flip [package settings → Public](https://github.com/users/AEON-7/packages/container/comfyui-aeon-spark/settings). Do **not** try to authenticate as someone else. |
| `download summary: ... N failed` with N>0 | flaky network or revoked HF token | Re-run `docker compose up -d --force-recreate` after `rm $WORKSPACE/workspace/.models_seeded`. If `403` lines appear in the log, the user's HF token is missing scopes — ask for a fresh one. |
| First-time launch sits at `Starting server` for >10 min | first-call PTX→SASS JIT cache warming up | Wait. The cache lands in `$WORKSPACE/workspace/.cache/`. Subsequent launches are seconds. |
| `OOM` during first generation | unified-memory overrun (Spark caps at 0.88) | Have the user swap a `*_bf16.safetensors` text encoder to `*_fp4_mixed.safetensors` in the loader widget — saves ~24 GB instantly via NVFP4 path. |
| ComfyUI says "missing nodes" on a user-imported workflow | needs custom-node pack not bundled | Use the in-UI Manager → "Install Missing Custom Nodes". It already has the right backend (`--enable-manager` + the pip pkg). |
| `docker compose up` says port 8188 in use | another ComfyUI / vLLM instance is bound | `docker stop vllm-aeon-ultimate-v2` (or whatever's on it) **after** asking the user. Spark has one GPU — only one heavy consumer at a time. |
| `Sage : unavailable` in entrypoint output | image was edited / sageattention deleted | **Do not pip install sageattention manually** — it must be the sm_121a-compiled wheel that ships in the image. `docker compose pull && up -d --force-recreate`. |
| Container restarts every ~30s | health check failing because ComfyUI is still loading the first time | Increase `start_period` in compose to `1200s`. First start with cold model cache can exceed the default 600s. |

---

## 7 · Things you must NOT do

- **Do not modify** `--use-sage-attention`, `--disable-pinned-memory`, `--enable-manager`, `TORCH_COMPILE_DISABLE=1`, or `PYTORCH_ALLOC_CONF` without asking. They are tuned for DGX Spark.
- **Do not enable** `torch.compile` / `TORCHDYNAMO_DISABLE=0` / xformers / FlashAttention. Triton can't emit working SASS for sm_121a yet — these will silently corrupt output or crash.
- **Do not delete** `$WORKSPACE/workspace/` to "fix" anything. That's 285 GB of weights + the user's outputs and saved workflows.
- **Do not push** any image you build to GHCR unless the user asks. The published image is the canonical artifact.
- **Do not bypass** the visibility check by assuming the package is private. Run the `curl` test in §4.
- **Do not change** the volume layout to a per-subdirectory mount. The single-volume-per-workspace design is intentional.
- **Do not commit** the `.env` file or any model `.safetensors` to git. They're in `.gitignore` for a reason.

---

## 8 · Where state lives (do not lose track)

```
$WORKSPACE/                                    # host-side
├── .env                                       # secrets — DO NOT log/echo
├── docker-compose.yml                         # the launcher
└── workspace/                                 # mounted into the container
    ├── .models_seeded                         # sentinel; delete to force re-download
    ├── models/                                # 285 GB pre-staged
    ├── custom_nodes/                          # 14 bundled + Manager-installed
    ├── output/                                # generated images / videos / audio
    ├── input/                                 # user's reference inputs
    ├── user/default/workflows/                # 8 seeded + user-saved
    └── .cache/huggingface/                    # HF download metadata
```

Inside the container, `/workspace/ComfyUI` is `$WORKSPACE/workspace/`. ComfyUI's own install is at `/opt/ComfyUI/` and is symlinked into the workspace by the entrypoint on first start.

---

## 9 · Customizing (the safe paths)

### 9.1 Add a workflow

Drop the JSON into `$WORKSPACE/workspace/user/default/workflows/`. No restart, no rebuild. The UI auto-discovers on next browser refresh.

### 9.2 Add a model

Drop the file into the matching `$WORKSPACE/workspace/models/<subdir>/`:
- DiT / UNet → `diffusion_models/`
- Full checkpoint → `checkpoints/`
- VAE → `vae/`
- Text encoder → `text_encoders/`
- LoRA → `loras/`
- Upscaler → `latent_upscale_models/`

ComfyUI loaders auto-rescan when their dropdown is opened.

### 9.3 Add a custom-node pack

Use the in-UI Manager. It writes to `$WORKSPACE/workspace/custom_nodes/<pack>/` and ComfyUI will pick it up after a UI-triggered reload.

### 9.4 Update ComfyUI itself

```bash
cd "$WORKSPACE"
docker compose pull
docker compose up -d
```

The `:latest` tag advances when this repo cuts a new release.

### 9.5 Bake new defaults into a forked image

Only if the user wants to redistribute. The repo at https://github.com/AEON-7/comfyui-aeon-spark has the full build context. Follow that README's *Build / push reference* section.

---

## 10 · Cross-platform fallback (non-Spark targets)

If pre-flight (§1) reports a different GPU, the image still runs but isn't compiled optimally for that arch. See the *Hardware Compatibility Matrix* in the repo README for per-GPU expectations. **Ask the user before proceeding** if they're not on a Spark — the deployment is the same but performance and required tweaks differ.

If they're on consumer Blackwell (RTX 5090/5080) and want a native-speed image, you'll need to rebuild for `linux/amd64` from the build context:

```bash
git clone https://github.com/AEON-7/comfyui-aeon-spark.git
cd comfyui-aeon-spark
DOCKER_BUILDKIT=1 docker buildx build --platform linux/amd64 \
  -t comfyui-aeon-spark:cu130-x86 .
```

That rebuild compiles SageAttention v3 against `sm_120` automatically (the build script reads the active `torch.cuda.get_device_capability()` and the ARM-base layer is replaced with `nvidia/cuda:13.0.2-devel-ubuntu24.04` x86). The user then runs the same `docker compose up -d` flow with the local image.

---

## 11 · Stop conditions — when to surface to the user

You are an agent helping a human. **Pause and ask** if:

- Pre-flight (§1) fails any check.
- The user's HF token isn't available or returns 401.
- §4 validation reports any failure.
- A workflow the user imported has missing nodes that aren't in the bundled set.
- The user wants to share GPU with another container (vLLM etc).
- Disk space is below 50 GB free at any point during model download.
- You're about to delete anything from `$WORKSPACE/workspace/`.
- You're about to modify the bundled launch flags.

For everything else: proceed and report what you did.

---

## 12 · Reporting back

When deployment finishes, report this template to the user (filling in measured values):

```
✓ Deployed ComfyUI · AEON DGX Spark on <hostname>
   - URL              : http://<host>:<port>
   - Image digest     : sha256:<digest from /system_stats>
   - GPU detected     : <name>  (<vram_total> GiB unified)
   - Models on disk   : <N>/28  (<size> GB total)
   - Workflows clean  : <N>/8
   - Container status : healthy / starting / unhealthy
   - First-generation latency note: PTX→SASS JIT cache warms on first kernel call;
     warm-cache latency will be 2-3× faster than the first run.

Open the URL in a browser. Try `01_flux2_text_to_image` first (smallest VRAM
footprint, fastest to feedback). For abliterated paths, use
`02_ltx2.3_T2V_I2V_distilled` — the abliterated Gemma LoRA is pre-applied.
```
