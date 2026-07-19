#!/usr/bin/env bash
# NOTE: intentionally NOT using `set -e` — a failed model download must never
# crash-loop the container. ComfyUI should always start so the pod is usable.
set -uo pipefail

# ---------------------------------------------------------------------------
# Config (override via RunPod env vars)
# ---------------------------------------------------------------------------
COMFYUI_DIR="${COMFYUI_DIR:-/opt/ComfyUI}"
WORKSPACE="${WORKSPACE:-/workspace}"          # RunPod network volume mount point
MODELS_DIR="${MODELS_DIR:-${WORKSPACE}/models}"
TEXT_ENCODER="${TEXT_ENCODER:-bf16}"          # bf16 = max prompt adherence | fp8 = smaller/faster
COMFY_ARGS="${COMFY_ARGS:---listen 0.0.0.0 --port 8188 --fast}"

HF_BASE="https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files"

echo "=================================================="
echo " FLUX.2 dev ComfyUI  |  volume: ${WORKSPACE}"
echo " text encoder: ${TEXT_ENCODER}"
echo "=================================================="
echo "==> Disk space (need ~150 GB free for bf16 encoder):"
df -h "${WORKSPACE}" 2>/dev/null || df -h /

# ---------------------------------------------------------------------------
# Persist models + outputs + user data on the volume
# ---------------------------------------------------------------------------
mkdir -p "${MODELS_DIR}"/{diffusion_models,text_encoders,vae,controlnet,loras,upscale_models}

for d in output input user; do
  mkdir -p "${WORKSPACE}/comfyui/${d}"
  rm -rf "${COMFYUI_DIR:?}/${d}"
  ln -sfn "${WORKSPACE}/comfyui/${d}" "${COMFYUI_DIR}/${d}"
done

# Drop bundled workflow(s) into the ComfyUI workflow browser (skip if already there)
WF_DIR="${WORKSPACE}/comfyui/user/default/workflows"
mkdir -p "${WF_DIR}"
if [[ -d /opt/comfy-assets/workflows ]]; then
  for wf in /opt/comfy-assets/workflows/*.json; do
    [[ -e "$wf" ]] || continue
    dst="${WF_DIR}/$(basename "$wf")"
    [[ -f "$dst" ]] || cp "$wf" "$dst"
  done
fi

# Point ComfyUI at the volume-backed model dirs
cat > "${COMFYUI_DIR}/extra_model_paths.yaml" <<YAML
runpod_volume:
  base_path: ${MODELS_DIR}/
  is_default: true
  checkpoints: checkpoints/
  diffusion_models: diffusion_models/
  unet: diffusion_models/
  text_encoders: text_encoders/
  clip: text_encoders/
  vae: vae/
  controlnet: controlnet/
  loras: loras/
  upscale_models: upscale_models/
YAML

# ---------------------------------------------------------------------------
# Download helper — parallel (aria2c), resumable, retried, and NON-FATAL.
# A failed download logs a warning and returns 1; it never exits the script.
# ---------------------------------------------------------------------------
dl() {
  local url="$1" out="$2"
  if [[ -f "$out" ]]; then
    echo "    [skip] $(basename "$out")"
    return 0
  fi
  echo "    [get ] $(basename "$out")"
  local dir file rc=1
  dir="$(dirname "$out")"; file="$(basename "$out")"
  if command -v aria2c >/dev/null 2>&1; then
    local hdr=()
    [[ -n "${HF_TOKEN:-}" ]] && hdr=(--header="Authorization: Bearer ${HF_TOKEN}")
    aria2c -x16 -s16 -k1M --continue=true --max-tries=5 --retry-wait=10 \
      --summary-interval=15 --console-log-level=warn \
      "${hdr[@]}" -d "$dir" -o "${file}.part" "$url" && rc=0 || rc=$?
  else
    local wa=()
    [[ -n "${HF_TOKEN:-}" ]] && wa=(--header "Authorization: Bearer ${HF_TOKEN}")
    wget -c --tries=5 --waitretry=10 --show-progress "${wa[@]}" -O "${out}.part" "$url" && rc=0 || rc=$?
  fi
  if [[ $rc -eq 0 && -f "${out}.part" ]]; then
    mv "${out}.part" "$out"
    return 0
  fi
  echo "    [WARN] download FAILED (rc=$rc) — $(basename "$out"). Check disk space / network."
  return 1
}

echo "==> Provisioning FLUX.2 core models (first boot only; ~85 GB with bf16 encoder)"
dl "${HF_BASE}/diffusion_models/flux2_dev_fp8mixed.safetensors" \
   "${MODELS_DIR}/diffusion_models/flux2_dev_fp8mixed.safetensors"

dl "${HF_BASE}/text_encoders/mistral_3_small_flux2_${TEXT_ENCODER}.safetensors" \
   "${MODELS_DIR}/text_encoders/mistral_3_small_flux2_${TEXT_ENCODER}.safetensors"

dl "${HF_BASE}/vae/flux2-vae.safetensors" \
   "${MODELS_DIR}/vae/flux2-vae.safetensors"

# FLUX.2 Fun ControlNet Union (depth / canny / MLSD) for the Blender depth-pass workflow.
# Loaded via the comfyui-flux2fun-controlnet node's own loader, NOT ComfyUI's native ControlNetLoader.
# Default = the -2602 checkpoint: authors' own notes say the plain version "performed poorly"
# (lost CFG distillation after control training); -2602 fixed that + added Scribble/Gray. Public, no token.
if [[ "${DOWNLOAD_CONTROLNET:-1}" == "1" ]]; then
  dl "https://huggingface.co/alibaba-pai/FLUX.2-dev-Fun-Controlnet-Union/resolve/main/models/Personalized_Model/FLUX.2-dev-Fun-Controlnet-Union-2602.safetensors" \
     "${MODELS_DIR}/controlnet/FLUX.2-dev-Fun-Controlnet-Union-2602.safetensors"
fi

# ---------------------------------------------------------------------------
# Optional extra downloads (e.g. ControlNet model when you're ready)
#   PROVISION_URLS="<url>|controlnet/name.safetensors  <url2>|loras/x.safetensors"
# ---------------------------------------------------------------------------
if [[ -n "${PROVISION_URLS:-}" ]]; then
  echo "==> Extra provisioning downloads"
  for entry in ${PROVISION_URLS}; do
    dl "${entry%%|*}" "${MODELS_DIR}/${entry##*|}"
  done
fi

# ---------------------------------------------------------------------------
# Launch — always runs, even if a download failed (pod must not crash-loop)
# ---------------------------------------------------------------------------
missing=0
for f in \
  "${MODELS_DIR}/diffusion_models/flux2_dev_fp8mixed.safetensors" \
  "${MODELS_DIR}/text_encoders/mistral_3_small_flux2_${TEXT_ENCODER}.safetensors" \
  "${MODELS_DIR}/vae/flux2-vae.safetensors" ; do
  [[ -f "$f" ]] || { echo "    [MISSING] $(basename "$f")"; missing=1; }
done
if [[ $missing -eq 1 ]]; then
  echo "==> WARNING: some core models are missing (likely disk space). ComfyUI will still start,"
  echo "    but generation needs those files. Increase Container Disk to ~150 GB and restart."
fi

echo "==> Starting ComfyUI: ${COMFY_ARGS}"
cd "${COMFYUI_DIR}"
exec python main.py ${COMFY_ARGS}
