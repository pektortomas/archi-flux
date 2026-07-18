#!/usr/bin/env bash
set -euo pipefail

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

# ---------------------------------------------------------------------------
# Persist models + outputs + user data on the volume
# ---------------------------------------------------------------------------
mkdir -p "${MODELS_DIR}"/{diffusion_models,text_encoders,vae,controlnet,loras,upscale_models}

for d in output input user; do
  mkdir -p "${WORKSPACE}/comfyui/${d}"
  rm -rf "${COMFYUI_DIR:?}/${d}"
  ln -sfn "${WORKSPACE}/comfyui/${d}" "${COMFYUI_DIR}/${d}"
done

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
# Download helper (resumable, skips if present, optional HF token for gated repos)
# ---------------------------------------------------------------------------
dl() {
  local url="$1" out="$2"
  if [[ -f "$out" ]]; then
    echo "    [skip] $(basename "$out")"
    return
  fi
  echo "    [get ] $(basename "$out")"
  local auth=()
  [[ -n "${HF_TOKEN:-}" ]] && auth=(--header "Authorization: Bearer ${HF_TOKEN}")
  wget -q --show-progress -c "${auth[@]}" -O "${out}.part" "$url"
  mv "${out}.part" "$out"
}

echo "==> Provisioning FLUX.2 core models (first boot only; ~85 GB with bf16 encoder)"
dl "${HF_BASE}/diffusion_models/flux2_dev_fp8mixed.safetensors" \
   "${MODELS_DIR}/diffusion_models/flux2_dev_fp8mixed.safetensors"

dl "${HF_BASE}/text_encoders/mistral_3_small_flux2_${TEXT_ENCODER}.safetensors" \
   "${MODELS_DIR}/text_encoders/mistral_3_small_flux2_${TEXT_ENCODER}.safetensors"

dl "${HF_BASE}/vae/flux2-vae.safetensors" \
   "${MODELS_DIR}/vae/flux2-vae.safetensors"

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
# Launch
# ---------------------------------------------------------------------------
echo "==> Starting ComfyUI: ${COMFY_ARGS}"
cd "${COMFYUI_DIR}"
exec python main.py ${COMFY_ARGS}
