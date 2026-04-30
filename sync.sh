#!/usr/bin/env bash
# =============================================================================
# ComfyUI · AEON DGX Spark — incremental sync
#
# For users who already deployed and want to pull the latest:
#   - new bundled custom-node packs (via image pull)
#   - new pre-seeded workflows (via repo pull → seeded into volume on next boot)
#   - new auto-downloaded model files (via download_models.py update + re-run)
#
# Without losing anything they already installed via Manager, downloaded, or
# tweaked. The entrypoint's seeders are idempotent: they only ADD missing
# files, never overwrite or delete user content.
#
# Usage:
#   ./sync.sh                  # incremental update, prompts before model fetch
#   ./sync.sh --yes            # non-interactive (for agents / cron)
#   ./sync.sh --no-models      # only sync image + workflows + scripts, skip
#                              # model downloader (saves bandwidth if you
#                              # don't want new models yet)
#
# What it does, in order:
#   1. Pull the latest image from GHCR (any new bundled packs come this way)
#   2. Update local repo files (workflows/, download_models.py, scripts) —
#      via `git pull` if it's a git checkout, otherwise via shallow re-clone.
#   3. Show a diff summary: new/changed workflows, new model entries, deltas
#      in custom-node bundle.
#   4. Optionally prompt for confirmation.
#   5. Recreate the container — entrypoint seeds anything new without touching
#      your existing files.
#   6. Tail logs and surface the per-item Seeding / ⤓ / ✓ done lines so you can
#      see exactly what changed.
# =============================================================================
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
ENV_FILE=".env"
COMPOSE_FILE="docker-compose.yml"
REPO_URL="https://github.com/AEON-7/comfyui-aeon-spark.git"

# ── ANSI ────────────────────────────────────────────────────────────────────
B=$'\033[1m'  D=$'\033[0m'
G=$'\033[1;32m'  Y=$'\033[1;33m'  R=$'\033[1;31m'  C=$'\033[1;36m'

# ── Args ────────────────────────────────────────────────────────────────────
YES=0; SKIP_MODELS=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y) YES=1 ;;
    --no-models) SKIP_MODELS=1 ;;
    --help|-h)
      sed -n '4,30p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *)
      echo "${R}✗${D} Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

confirm() {
    [ "$YES" = "1" ] && return 0
    local reply; read -r -p "$1 [Y/n] " reply
    case "${reply:-Y}" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# ── Pre-flight ──────────────────────────────────────────────────────────────
[ -f "$COMPOSE_FILE" ] || { echo "${R}✗${D} run from the deploy directory (where $COMPOSE_FILE lives)"; exit 1; }
[ -f "$ENV_FILE" ]    || { echo "${R}✗${D} no .env present — run ./setup.sh first"; exit 1; }

cat <<EOF
${B}╔════════════════════════════════════════════════════════════════╗
║       ComfyUI · AEON DGX Spark — Incremental Sync              ║
╚════════════════════════════════════════════════════════════════╝${D}

EOF

# ── Step 1: pull latest image ───────────────────────────────────────────────
. <(grep -E '^(IMAGE_TAG|COMFYUI_PORT)=' "$ENV_FILE" 2>/dev/null || true)
IMAGE_TAG="${IMAGE_TAG:-latest}"
IMAGE="ghcr.io/aeon-7/comfyui-aeon-spark:${IMAGE_TAG}"

echo "${C}━━━ 1/5: Pull latest image (${IMAGE_TAG}) ━━━${D}"
prev_image_id=$(docker images --no-trunc --format "{{.ID}}" "$IMAGE" 2>/dev/null | head -1)
docker compose pull comfyui ollama 2>&1 | tail -8
new_image_id=$(docker images --no-trunc --format "{{.ID}}" "$IMAGE" 2>/dev/null | head -1)
if [ "$prev_image_id" = "$new_image_id" ]; then
    echo "${G}✓${D} image already at latest digest"
else
    echo "${G}✓${D} image updated"
    echo "    was: ${prev_image_id:7:12}"
    echo "    now: ${new_image_id:7:12}"
fi

# ── Step 2: refresh local repo files (workflows/, scripts, downloader) ──────
echo
echo "${C}━━━ 2/5: Refresh local scripts & workflows from GitHub ━━━${D}"

# Pre-pull snapshots of the files that matter for diffing
mkdir -p .sync-old
cp -a workflows .sync-old/workflows 2>/dev/null || true
cp -a download_models.py .sync-old/download_models.py 2>/dev/null || true

if [ -d .git ]; then
    echo "  git checkout detected — running 'git pull --ff-only'"
    git fetch --quiet origin
    if git pull --ff-only --quiet origin "$(git rev-parse --abbrev-ref HEAD)" 2>&1 | tee /dev/stderr | grep -q "fatal"; then
        echo "${Y}⚠${D}  git pull had conflicts; falling back to snapshot fetch"
        IS_GIT=0
    else
        echo "${G}✓${D} repo updated"
        IS_GIT=1
    fi
else
    IS_GIT=0
fi

if [ "$IS_GIT" = "0" ]; then
    echo "  no git repo here — fetching the runtime files from GitHub directly"
    TMPDIR=$(mktemp -d)
    git clone --depth=1 --quiet "$REPO_URL" "$TMPDIR/repo"
    for item in workflows download_models.py setup.sh sync.sh; do
        if [ -e "$TMPDIR/repo/$item" ]; then
            rm -rf "./$item"
            cp -a "$TMPDIR/repo/$item" "./$item"
        fi
    done
    chmod +x setup.sh sync.sh 2>/dev/null || true
    rm -rf "$TMPDIR"
    echo "${G}✓${D} runtime files refreshed (workflows, download_models.py, setup.sh, sync.sh)"
fi

# ── Step 3: compute the diff ────────────────────────────────────────────────
echo
echo "${C}━━━ 3/5: Diff vs your current state ━━━${D}"

# 3a. New workflows (in repo but not yet in the user's volume)
WORKSPACE_WF="./workspace/user/default/workflows"
new_workflows=()
if [ -d workflows ] && [ -d "$WORKSPACE_WF" ]; then
    for f in workflows/*.json; do
        [ -e "$f" ] || continue
        name=$(basename "$f")
        # The volume has the workflow already if there's a file with the same name
        if [ ! -f "$WORKSPACE_WF/$name" ]; then
            new_workflows+=("$name")
        fi
    done
fi

# 3b. New download entries (lines in download_models.py that weren't in old version)
new_model_lines=()
if [ -f .sync-old/download_models.py ] && [ -f download_models.py ]; then
    while IFS= read -r line; do
        new_model_lines+=("$line")
    done < <(grep -F '"' download_models.py | grep -F '.safetensors' | \
             sort -u | comm -23 - <(grep -F '"' .sync-old/download_models.py | \
             grep -F '.safetensors' | sort -u))
fi

# 3c. Image change marker (we already detected new vs prev image_id above)
image_changed="no"
[ "$prev_image_id" != "$new_image_id" ] && image_changed="yes"

cat <<EOF
  ${B}Image:${D}        $([ "$image_changed" = "yes" ] && echo "${G}updated${D}" || echo "no change")
  ${B}Workflows:${D}    ${#new_workflows[@]} new
EOF
for w in "${new_workflows[@]}"; do echo "                ${G}+${D} $w"; done
echo "  ${B}Models:${D}       ${#new_model_lines[@]} new download entries"
for m in "${new_model_lines[@]:0:5}"; do
    fname=$(echo "$m" | grep -oE '[a-zA-Z0-9_./-]+\.safetensors' | head -1)
    echo "                ${G}+${D} ${fname:-$(echo $m | head -c 80)}"
done
[ "${#new_model_lines[@]}" -gt 5 ] && echo "                  ... and $((${#new_model_lines[@]} - 5)) more"

if [ "$image_changed" != "yes" ] && [ "${#new_workflows[@]}" = "0" ] && [ "${#new_model_lines[@]}" = "0" ]; then
    echo
    echo "${G}✓${D} you're already up-to-date — nothing to sync"
    rm -rf .sync-old
    exit 0
fi

# ── Step 4: confirm ─────────────────────────────────────────────────────────
echo
if [ "${#new_model_lines[@]}" -gt 0 ] && [ "$SKIP_MODELS" = "0" ]; then
    echo "${Y}⚠${D}  Recreating the container will trigger the model downloader."
    echo "   Files already on disk are skipped (idempotent), but the new"
    echo "   entries above WILL pull. Press Enter once you've reviewed."
    if ! confirm "Proceed?"; then
        echo "Aborted."; rm -rf .sync-old; exit 0
    fi
fi

# ── Step 5: recreate container ──────────────────────────────────────────────
echo
echo "${C}━━━ 4/5: Recreate container ━━━${D}"
if [ "$SKIP_MODELS" = "1" ]; then
    SKIP_MODEL_DOWNLOAD=1 docker compose up -d --force-recreate 2>&1 | tail -5
    echo "${G}✓${D} skipped model downloader (--no-models)"
else
    # Don't delete the .models_seeded sentinel — the downloader is idempotent
    # by basename, so it'll skip files already on disk and only pull new entries.
    docker compose up -d --force-recreate 2>&1 | tail -5
fi

# ── Step 6: stream the diff-relevant log lines ──────────────────────────────
echo
echo "${C}━━━ 5/5: Watching for new items to land ━━━${D}"
echo "  (press Ctrl-C to detach — sync continues in background)"
echo
docker compose logs -f comfyui 2>&1 | \
  grep -E --line-buffered "Seeding (custom node|workflow):|⤓ |✓ done:|download summary:|Launching ComfyUI" | \
  awk '
    /Launching ComfyUI/ { print; print ""; print "✓ Sync complete"; exit }
    /Seeding/   { print "  + " $0; next }
    /⤓/         { print "  ↓ " $0; next }
    /✓ done/    { print "  ✓ " $0; next }
    /download summary/ { print "  ∑ " $0; next }
    { print }
  '

rm -rf .sync-old
