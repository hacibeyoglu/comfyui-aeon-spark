# AGENTS.md

> Deployment guide for AI agents — how to install and validate this image on a
> NVIDIA DGX Spark host. **Follow the sections in order.** Every command is
> copy-pasteable. Stop conditions are marked **STOP →**.

---

## 0 · Identity

**Repository:** `AEON-7/comfyui-aeon-spark`
**Image (default):** `ghcr.io/aeon-7/comfyui-aeon-spark:latest` (= `:full`, 17 GB — auto-downloads ~285 GB of weights on first start using user's HF_TOKEN)
**Alternate (no weights):** `ghcr.io/aeon-7/comfyui-aeon-spark:slim` (= `:base`, 17 GB — zero auto-download, user picks every model via in-UI Manager)

No image variant pre-embeds weights. The downloader runs server-side under the user's HF token, so each model's license is accepted by the user at HuggingFace, never by us as a redistributor.
**Purpose:** ComfyUI workstation pre-loaded with Flux 2 Dev, LTX 2.3 22B, and ACE-Step v1.5 XL Turbo, optimized for DGX Spark (GB10 / Blackwell / **sm_121a**).
**You are deploying onto:** a single DGX Spark host with Docker installed.
**Approximate disk needed:**
- **`:latest` (= `:full`)**: **350 GB** (17 GB image + 285 GB workspace for downloaded models + headroom).
- **`:slim`**: **50 GB initially** (17 GB image + ~30 GB headroom for whatever the user installs via UI).

**Approximate time to first generation:**
- **`:latest`**: **~50 minutes** on first start (image pull ~5 min + model download ~45 min — bound by HF bandwidth). Subsequent restarts: seconds.
- **`:slim`**: **~5 minutes** image pull, then user picks models on-demand via UI (each download is server-side).

Pick **`:latest` (= `:full`)** for normal deployments where the user has an HF account and wants the bundled stack ready to run.
Pick **`:slim`** when:
- The user wants total control over which models land on disk.
- The user has restricted HF access or prefers community-hosted alternatives.
- The user prefers to install each model interactively via the UI Manager.

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

1. **Image tag.** `latest` (= `:full`, auto-downloads ~285 GB of weights on first start) or `slim` (no auto-download — user installs each model interactively via the UI Manager). Default: `latest`.

2. **HuggingFace token** (`hf_AbCd1234...`, read scope). Required for `:latest` (the downloader uses it). Optional but recommended for `:slim` (the user will likely install gated models via the UI later). Ask the user: *"Please provide your HuggingFace access token (read scope; create one at https://huggingface.co/settings/tokens)."*  **Do not invent or guess a token.**

3. **Gated repo licenses accepted.** Three BFL repos are gated and the HF token alone is NOT enough — the user must individually click "Agree and access" on each:
   - https://huggingface.co/black-forest-labs/FLUX.2-dev (workflow 01)
   - https://huggingface.co/black-forest-labs/FLUX.2-klein-base-9b-fp8 (workflow 08)
   - https://huggingface.co/black-forest-labs/FLUX.2-small-decoder (canonical Flux 2 VAE)

   Ask the user: *"Please open these three URLs in a browser, sign in, and click 'Agree and access repository'. Reply 'done' when complete."* If the user skips this, the downloader will report 403 errors on those specific files (other models will still work).

4. **Workspace path on the host.** Default: `~/comfyui-spark`. If the user has another mount with more space, ask.

5. **Whether to skip the abliterated full-LLM snapshots** (~70 GB saved). Default: keep them — they're swap-in alternatives for the abliterated text-encoder paths. Ask only if disk is tight.

6. **Public port** for the UI. Default: `8188`. Only ask if there's a conflict.

---

## 3 · One-shot deployment

**Preferred path: have the user run `./setup.sh`.** It interactively walks them through HF token, gated-license accepts, variant choice (`:latest` vs `:slim`), port, `SKIP_ABLITERATED`, and launch. It hides the token as they paste it and writes a `chmod 600` `.env`.

If they're not at a TTY (e.g. you're scripting it remotely), use the heredoc block below instead.

```bash
# ── parameters ──────────────────────────────────────────────────────────────
IMAGE_TAG="${IMAGE_TAG:-latest}"             # `latest` (auto-download) or `slim` (no-download)
WORKSPACE="${WORKSPACE:-$HOME/comfyui-spark}"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"
SKIP_ABLITERATED="${SKIP_ABLITERATED:-0}"   # set to 1 to skip the ~70 GB huihui-ai snapshots
# HF_TOKEN is required for `:latest` (the downloader pulls gated repos).
# It is OPTIONAL but recommended for `:slim` (the user will likely install
# gated models via the UI Manager later).
HF_TOKEN="${HF_TOKEN:-}"
if [ "$IMAGE_TAG" = "latest" ] || [ "$IMAGE_TAG" = "full" ] || [ "$IMAGE_TAG" = "bf16-flux2-ltx2.3" ] || [ "$IMAGE_TAG" = "cu130-sm121a" ]; then
    : "${HF_TOKEN:?must be set when using the auto-download tag; ask user for hf_... read token}"
fi
# ────────────────────────────────────────────────────────────────────────────

mkdir -p "$WORKSPACE/workspace"
cd "$WORKSPACE"

# Drop the .env (used by docker compose for variable substitution)
cat > .env <<EOF
HF_TOKEN=$HF_TOKEN
COMFYUI_PORT=$COMFYUI_PORT
IMAGE_TAG=$IMAGE_TAG
SKIP_ABLITERATED=$SKIP_ABLITERATED
EOF
chmod 600 .env

# Drop the docker-compose.yml
# NOTE: the YAML below uses 'YAML' (quoted) heredoc so $-expressions stay
# literal — docker compose substitutes them from .env at run time.
cat > docker-compose.yml <<'YAML'
services:
  ollama:
    image: ollama/ollama:latest
    container_name: comfyui-ollama
    runtime: nvidia
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    environment:
      OLLAMA_HOST: "0.0.0.0:11434"
      OLLAMA_KEEP_ALIVE: "24h"
    volumes:
      - ./workspace/.ollama:/root/.ollama
    entrypoint: >-
      /bin/sh -c '
      /bin/ollama serve &
      sleep 5;
      /bin/ollama pull "${OLLAMA_PRELOAD_MODEL:-gemma3:4b}" || true;
      wait
      '
    healthcheck:
      test: ["CMD", "/bin/ollama", "list"]
      interval: 30s
      timeout: 10s
      start_period: 120s
      retries: 5
    restart: unless-stopped

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
    depends_on:
      ollama:
        condition: service_healthy
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:8188/system_stats >/dev/null || exit 1"]
      interval: 30s
      timeout: 10s
      start_period: 600s
      retries: 5
YAML

# Pull and start
docker pull "ghcr.io/aeon-7/comfyui-aeon-spark:$IMAGE_TAG"
docker pull ollama/ollama:latest
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

# 4.1 Both containers are healthy
docker ps --filter "name=comfyui-spark" --format "{{.Names}} {{.Status}}" | grep -q "healthy\|Up"
docker ps --filter "name=comfyui-ollama" --format "{{.Names}} {{.Status}}" | grep -q "healthy\|Up"

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
required = ['--use-sage-attention', '--bf16-unet', '--disable-pinned-memory', '--enable-manager', '--enable-assets']
missing = [f for f in required if f not in argv]
assert not missing, f'Missing flags: {missing}'
print('OK: all critical flags present')
"

# 4.5 Ollama sidecar reachable from comfyui (workflow 09 prerequisite)
docker exec comfyui-spark curl -fsS -m 5 http://ollama:11434/api/version >/dev/null \
  && echo "OK: ollama reachable" || echo "FAIL: ollama unreachable"

# 4.6 Model files on disk (only on :latest variant — :slim starts empty by design)
if [ "$IMAGE_TAG" = "latest" ] || [ "$IMAGE_TAG" = "full" ] || [ "$IMAGE_TAG" = "bf16-flux2-ltx2.3" ] || [ "$IMAGE_TAG" = "cu130-sm121a" ]; then
  docker exec comfyui-spark bash -c "find /workspace/ComfyUI/models -type f \\( -name '*.safetensors' -o -name '*.ckpt' \\) ! -path '*/.cache/*' | wc -l" \
    | (read n; [ "$n" -ge 30 ] && echo "OK: $n model files present" || echo "WARN: only $n model files (expect 30+; may be running first-start download still)")
else
  echo "skipping model count check — :slim image starts with no models"
fi

# 4.7 Every seeded workflow's nodes resolve
python3 <<'PY'
import json, urllib.request, glob, os, re, sys
PORT = os.environ.get('COMFYUI_PORT', '8188')
ni = json.loads(urllib.request.urlopen(f'http://127.0.0.1:{PORT}/object_info', timeout=15).read())
# Backend nodes + frontend-only litegraph nodes (these aren't in /object_info)
present = set(ni) | {'MarkdownNote','Note','Reroute','PrimitiveNode','GetNode','SetNode',
                     'Bookmark (rgthree)','Fast Bypasser (rgthree)','Label (rgthree)',
                     'Fast Groups Bypasser (rgthree)','Fast Groups Muter (rgthree)'}
uuid = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}')
ws = os.path.expanduser(os.environ.get('WORKSPACE', os.path.expanduser('~/comfyui-spark')) + '/workspace/user/default/workflows/')
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

If 4.7 reports missing nodes, the user has imported a workflow that needs a custom-node pack we didn't bundle. The fix: in the ComfyUI UI top bar, click **Manager → Install Missing Custom Nodes**. The Manager is already wired (`--enable-manager` is on). Do **not** try to install custom nodes manually with pip — Manager handles it correctly server-side.

If 4.6 reports a 403 in the download log, the user hasn't accepted one of the gated repo licenses. **STOP →** ask the user to visit the URLs in §2 step 3 and click "Agree and access", then re-run with `rm $WORKSPACE/workspace/.models_seeded && docker compose up -d --force-recreate`.

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
  | `10_ltx2.3_prompt_relay` | LTX 2.3 distilled-1.1 fp8 + Kijai PromptRelay timeline-based per-second prompt control for video |
- ComfyUI-Manager wired and clickable in the top bar (for installing additional nodes/models server-side).
- **Workflow Overview → Missing Models → Download** routes through the bundled `aeon-server-side-downloads` extension — clicks go server-side via Manager's queue API, file lands in `$WORKSPACE/workspace/models/`, never on the client browser.
- Persistent workspace at `$WORKSPACE/workspace/` — survives container recreations.

---

## 6 · Common failure patterns and exact fixes

| Symptom | Likely cause | Exact fix |
| --- | --- | --- |
| `docker pull` returns 401/403 | image visibility was reverted to private | Tell the user to flip [package settings → Public](https://github.com/users/AEON-7/packages/container/comfyui-aeon-spark/settings). Do **not** try to authenticate as someone else. |
| `download summary: ... N failed` with `403 Cannot access gated repo` lines | user hasn't clicked "Agree and access" on the gated BFL repos (see §2 step 3) | Have user open each gated URL → sign in → "Agree and access". Then `rm $WORKSPACE/workspace/.models_seeded && docker compose up -d --force-recreate` — only the failed files re-download. |
| `download summary: ... N failed` with `401 Unauthorized` lines | HF token wrong, expired, or missing read scope | Have user generate a fresh read-scope token at https://huggingface.co/settings/tokens, update `.env`, then `docker compose up -d --force-recreate`. |
| `download summary: ... N failed` with random network errors | flaky upstream | Just re-run: `rm $WORKSPACE/workspace/.models_seeded && docker compose up -d --force-recreate`. The downloader is idempotent — files already on disk are skipped. |
| First-time launch sits at `Starting server` for >10 min | first-call PTX→SASS JIT cache warming up | Wait. The cache lands in `$WORKSPACE/workspace/.cache/nv/`. Subsequent launches are seconds. |
| `OOM` during first generation | unified-memory overrun (Spark caps at 0.88) | Swap a `*_bf16.safetensors` text encoder to `*_fp4_mixed.safetensors` in the loader widget — saves ~24 GB instantly via NVFP4 path. |
| Workflow says "missing models" when loaded in UI | model file not on disk yet | TWO server-side paths: (a) **Manager → Install Missing Models** (top-bar button) uses Manager's `/v2/manager/queue/batch`. (b) **Workflow Overview → Errors → Missing Models → Download all / Download** in the new ComfyUI 0.20 sidebar; the bundled `aeon-server-side-downloads` JS extension intercepts those clicks and routes them through the same server-side API, then pops a toast confirming "Queueing N file(s) for server-side download". Both write to `$WORKSPACE/workspace/models/<dir>/` on the **server**. |
| Workflow says "missing nodes" when loaded | needs a custom-node pack not bundled | Use the in-UI Manager top-bar button → **Install Missing Custom Nodes** (the new `comfyui-manager` pip pkg + `--enable-manager` wire this up). Do **not** pip-install custom nodes manually. |
| User clicks "Download" in Workflow-Overview, file ends up on the client laptop instead of the server | the bundled `aeon-server-side-downloads` JS extension didn't load (browser cache, or pack got removed from `workspace/custom_nodes/`) | (1) Hard-refresh the browser (Ctrl-Shift-R / Cmd-Shift-R). (2) Verify the pack exists: `ls $WORKSPACE/workspace/custom_nodes/aeon-server-side-downloads/web/server-side-downloads.js`. (3) If missing, restart container: `docker compose restart comfyui` — the entrypoint re-seeds it from `/opt/bundled_custom_nodes/`. (4) Confirm with `curl -s http://<host>:8188/extensions/aeon-server-side-downloads/server-side-downloads.js \| head -5`. |
| Workflow 09 (AceStep) says `ConnectionError ... Ollama` | Ollama sidecar isn't reachable from comfyui's container | `docker compose ps` should show `comfyui-ollama` healthy. If down, `docker compose up -d ollama`. The sidecar auto-pulls `gemma3:4b` on first start. |
| Workflow 09 wants a different Ollama model | user's prompt-expansion preferences | Have user run `docker exec comfyui-ollama ollama pull <model-name>`, then in the workflow's `OllamaConnectivityV2` widget swap the model name from `gemma3:4b` to whatever they pulled. |
| `docker compose up` says port 8188 in use | another ComfyUI / vLLM instance is bound | `docker stop vllm-aeon-ultimate-v2` (or whatever's on it) **after** asking the user. Spark has one GPU — only one heavy consumer at a time. |
| `Sage : unavailable` in entrypoint output | image was edited / sageattention deleted | **Do not pip install sageattention manually** — it must be the sm_121a-compiled wheel that ships in the image. `docker compose pull && docker compose up -d --force-recreate`. |
| `Crystools ... pynvml is not installed` | image was edited or a stale image is still pulled | `docker compose pull` to grab the current image, then recreate. Modern image has pynvml installed. |
| Container restarts every ~30s | health check failing because ComfyUI is still loading the first time | Increase `start_period` in compose to `1200s`. First start with cold model cache can exceed the default 600s. |

---

## 7 · Things you must NOT do

- **Do not modify** `--use-sage-attention`, `--disable-pinned-memory`, `--enable-manager`, `--enable-assets`, `TORCH_COMPILE_DISABLE=1`, or `PYTORCH_ALLOC_CONF` without asking. They are tuned for DGX Spark; changing them silently degrades or breaks runs.
- **Do not enable** `torch.compile` / `TORCHDYNAMO_DISABLE=0` / xformers / FlashAttention. Triton can't emit working SASS for sm_121a yet — these will silently corrupt output or crash.
- **Do not delete** `$WORKSPACE/workspace/` to "fix" anything. On `:latest` that's ~285 GB of weights; on `:slim` it's the user's saved workflows / outputs / Manager-installed nodes. Always survives container recreation; deleting it is a major data-loss event.
- **Do not push** any image you build to GHCR unless the user asks. The published image is the canonical artifact.
- **Do not bake model weights into a derived image and publish it.** Several bundled models (FLUX.2, Mistral-Small-3, Gemma) have non-commercial / research-use / gated licenses that prohibit redistribution. The published image variants deliberately ship code only; the user pulls weights from HF under their own account.
- **Do not pip-install** sageattention, comfyui-manager, or any custom-node pack inside the container manually. The image's compiled wheel and pre-resolved deps are the source of truth — manual installs can replace working sm_121a wheels with broken stock ones. If a pack needs adding, it goes through the in-UI Manager (which uses the right server-side install path).
- **Do not bypass** the visibility check by assuming the package is private. Run the `curl` test in §4.
- **Do not change** the volume layout to a per-subdirectory mount. The single-volume-per-workspace design is intentional.
- **Do not stop or remove the Ollama sidecar** unless the user explicitly does not need workflow 09 (AceStep audio). Workflow 09 fails at runtime without it.
- **Do not commit** the `.env` file or any model `.safetensors` to git. They're in `.gitignore` for a reason.

---

## 8 · Where state lives (do not lose track)

```
$WORKSPACE/                                    # host-side
├── .env                                       # HF_TOKEN + tunables — DO NOT log/echo or commit
├── docker-compose.yml                         # the launcher
└── workspace/                                 # mounted into the container
    ├── .models_seeded                         # sentinel; delete to force re-download (on :latest)
    ├── .ollama/                               # Ollama model cache (gemma3:4b lives here)
    ├── models/                                # ~285 GB on :latest after first start; empty on :slim
    │   ├── diffusion_models/  checkpoints/  text_encoders/  vae/  loras/  ...
    ├── custom_nodes/                          # 16 bundled (seeded on first start) + Manager-installed
    ├── output/                                # generated images / videos / audio
    ├── input/                                 # user's reference inputs
    ├── user/default/workflows/                # 8 seeded + anything the user saves
    └── .cache/                                # HF + nv (PTX→SASS JIT) caches
```

Inside the `comfyui` container, `/workspace/ComfyUI` is mapped to `$WORKSPACE/workspace/`. ComfyUI's own install is at `/opt/ComfyUI/` (in the image) and the entrypoint symlinks the user-data subdirs into the volume on first start.

The `ollama` container has its own state at `$WORKSPACE/workspace/.ollama/` so the `gemma3:4b` model survives container recreations.

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

### 9.4 Update ComfyUI itself / pull new workflows + models

```bash
cd "$WORKSPACE"
./sync.sh --yes              # incremental: pulls latest image, refreshes
                             # workflows/, runs idempotent downloader on
                             # any new entries — preserves user volume
```

`sync.sh` does:
1. `docker compose pull` (pulls latest image; new bundled custom nodes come this way)
2. `git pull` (or shallow re-clone) the repo so `workflows/` + `download_models.py` + `setup.sh` + `entrypoint.sh` are current
3. Diffs against the user's volume — reports new workflows, new model-download entries, image change
4. Recreates the container — entrypoint's idempotent seeders ADD missing files only, never overwrite or delete user content
5. Tails the boot log filtered to "Seeding…", "⤓", "✓ done:", "download summary" so the agent can parse what landed

Flags useful in agent contexts:
- `--yes` — non-interactive
- `--no-models` — refresh code/workflows but skip the downloader (for low-bandwidth or pre-vetted-only workflows)

The `:latest` tag advances when this repo cuts a new release. Run `./sync.sh --yes` periodically (cron, manual, or agent-triggered) to stay current.

### 9.5 Add an Ollama model for prompt-expansion workflows

```bash
docker exec comfyui-ollama ollama pull <model>     # e.g. llama3.2:3b, qwen2.5:7b, etc.
```

Then in the workflow that uses it, edit the `OllamaConnectivityV2` widget to pick the new model name. The pull persists across container restarts because Ollama state is in the volume.

### 9.6 Add a workflow as a default for *future* fresh starts

Only relevant if the user wants to fork and redistribute their own image. The build context is at https://github.com/AEON-7/comfyui-aeon-spark — drop a `.json` into `workflows/`, `docker compose build`, push to your own GHCR namespace.

---

## 10 · Cross-platform fallback (non-Spark targets)

If pre-flight (§1) reports a different GPU, the image still runs but isn't compiled optimally for that arch. See the *Hardware Compatibility Matrix* in the repo README for per-GPU expectations. **Ask the user before proceeding** if they're not on a Spark — the deployment is the same but performance and required tweaks differ.

If they're on consumer Blackwell (RTX 5090/5080) and want a native-speed image, rebuild for `linux/amd64` with the right arch list:

```bash
git clone https://github.com/AEON-7/comfyui-aeon-spark.git
cd comfyui-aeon-spark
DOCKER_BUILDKIT=1 docker buildx build --platform linux/amd64 \
  --build-arg TORCH_CUDA_ARCH_LIST="12.0" \
  -t comfyui-aeon-spark:cu130-x86 .
```

That rebuild compiles SageAttention v3 against `sm_120` (consumer Blackwell). The user then runs the same `docker compose up -d` flow with the local image (replace the GHCR image ref with `comfyui-aeon-spark:cu130-x86`).

---

## 11 · Stop conditions — when to surface to the user

You are an agent helping a human. **Pause and ask** if:

- Pre-flight (§1) fails any check.
- The user hasn't accepted the gated-repo licenses in §2 step 3 (the downloader will 403 on those files).
- The user's HF token isn't available, returns 401, or expires.
- §4 validation reports any failure.
- A workflow the user imported has missing nodes that aren't in the bundled set (Manager → Install Missing Custom Nodes is the answer, but get user consent first).
- A workflow the user imported has missing **models** (Manager / Asset Browser → Install Missing Models is the answer; downloads server-side).
- The user wants to share GPU with another container (vLLM etc) — Spark has 1 GPU.
- Disk space is below 50 GB free at any point during model download.
- You're about to delete anything from `$WORKSPACE/workspace/`.
- You're about to modify the bundled launch flags.
- You're about to modify or remove the Ollama sidecar.
- You're considering pip-installing into the running container.

For everything else: proceed and report what you did.

---

## 12 · Reporting back

When deployment finishes, report this template to the user (filling in measured values):

```
✓ Deployed ComfyUI · AEON DGX Spark on <hostname>
   - URL              : http://<host>:<port>
   - Image            : ghcr.io/aeon-7/comfyui-aeon-spark:<tag>
   - GPU detected     : <name>  (<vram_total> GiB unified)
   - Containers       : comfyui-spark <healthy/starting>  · comfyui-ollama <healthy/starting>
   - Models on disk   : <N> files (<size> GB total) — :latest target ≥30, :slim target 0
   - Workflows clean  : <N>/8 — every loader value resolved
   - Ollama sidecar   : reachable, model = gemma3:4b
   - First-generation latency note: PTX→SASS JIT cache warms on first kernel call;
     warm-cache latency will be 2-3× faster than the first run.

Open the URL in a browser. Try `01_flux2_text_to_image` first (smallest VRAM
footprint, fastest to feedback). For abliterated paths, use
`02_ltx2.3_T2V_I2V_distilled` — the abliterated Gemma LoRA is pre-applied.

If a workflow says "missing models" when loaded, click **Install Missing Models**
in the UI top bar — downloads land server-side in your workspace volume, never
on the client browser.
```
