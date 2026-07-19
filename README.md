# runpod-flux2

Lean **ComfyUI + FLUX.2 [dev] FP8** image for RunPod, built via GitHub Actions.

The image stays small (~a few GB): **models are not baked in** — they download to your
RunPod **network volume** on first boot, so rebuilds are fast and pods start quickly on
later runs. LoRAs are intentionally left out for now; ControlNet nodes can be added via
the built-in ComfyUI-Manager when you're ready.

## What's inside

- CUDA 12.4 + PyTorch (cu124) — native **FP8** on Ada/Hopper (L40S / H100)
- ComfyUI (native FLUX.2 nodes) + ComfyUI-Manager + ControlNet preprocessors
- **FLUX.2 Fun ControlNet** node (`comfyui-flux2fun-controlnet`) baked in — depth / canny / MLSD
- **Bundled turnkey workflow** `flux2-depth-archviz` — depth pass in, rendered design out
- First-boot provisioning of:
  - `diffusion_models/flux2_dev_fp8mixed.safetensors`
  - `text_encoders/mistral_3_small_flux2_bf16.safetensors` (bf16 = best prompt adherence)
  - `vae/flux2-vae.safetensors`
  - `controlnet/FLUX.2-dev-Fun-Controlnet-Union.safetensors`

### Important: the ControlNet has its own loader

The official base FLUX.2 workflow is text-to-image + multi-reference editing — it does **not**
do proper depth-map ControlNet. For strict geometry from your Blender depth pass, use the
**flux2fun** nodes: load the ControlNet with the node pack's **own "Load ControlNet" node**
(ComfyUI's native `ControlNetLoader` rejects this file). Ready-to-use depth/canny workflows
ship in the node's `examples/` folder — start there. Depth conditioning scale ~**0.65–0.80**.

> This node is a fairly new community wrapper (confirmed working on fp8). Run a **mini-test on
> 2–3 Blender depth passes first** to confirm geometry adherence before committing the full pipeline.

## 1. Build (GitHub Actions → GHCR)

1. Push this repo to GitHub.
2. The workflow in `.github/workflows/build.yml` runs on every push to `main` (and on tags / manual dispatch) and pushes to **`ghcr.io/<owner>/<repo>:latest`**. No secrets needed — it uses the built-in `GITHUB_TOKEN`.
3. After the first successful run, open the package under your repo's **Packages** and either:
   - set it **Public** (simplest — RunPod can then pull without credentials), or
   - keep it private and add registry credentials in RunPod (see below).

## 2. RunPod template

Create a **Pod template** with:

| Setting | Value |
|---|---|
| Container image | `ghcr.io/<owner>/<repo>:latest` |
| Container disk | 20 GB (image + scratch only) |
| Volume / mount path | Network volume mounted at **`/workspace`** |
| Expose HTTP port | **8188** |
| GPU | **L40S (48 GB, FP8)** or **H100 (80 GB)** — *not A100 (no native FP8)* |

**Recommended network volume size: ~150 GB** (fp8 DiT ~35 GB + bf16 encoder ~48 GB + VAE + outputs + headroom).

### Environment variables (all optional)

| Var | Default | Purpose |
|---|---|---|
| `TEXT_ENCODER` | `bf16` | Set to `fp8` to halve encoder download/VRAM (slightly lower prompt adherence). |
| `HF_TOKEN` | — | Only needed if a download source is gated. The Comfy-Org mirror is public, so usually not required. |
| `COMFY_ARGS` | `--listen 0.0.0.0 --port 8188 --fast` | Override launch flags (e.g. drop `--fast` if you hit issues). |
| `PROVISION_URLS` | — | Extra downloads, space-separated `url\|subdir/filename` (see below). |
| `MODELS_DIR` | `/workspace/models` | Where models live on the volume. |

> **First boot downloads ~85 GB** (with bf16 encoder) to the volume — give it time. Every
> later pod start on the same volume skips downloads and launches in seconds.

## 3. Open ComfyUI — the workflow is already there

Once the pod is running, open the **:8188** HTTP endpoint from the RunPod dashboard. A ready
depth-ControlNet archviz workflow is preloaded: **Workflows → `flux2-depth-archviz`**. It's
wired end to end (FLUX.2 dev fp8 → mistral bf16 encoder → Fun ControlNet → sampler → save) with
all model names already pointing at the provisioned files. To render:

1. Open `flux2-depth-archviz`.
2. In the **"Load Blender DEPTH pass"** node, upload your Blender depth render (grayscale, white = near, black = far).
3. Edit the **Prompt** node to describe your design.
4. Queue. Adjust ControlNet **strength 0.65–0.80** if geometry drifts; steps 35, CFG 4, euler.

Default canvas is landscape **1536×1024** (~1.6 MP) — change the `width`/`height` primitives to
resize. The Fun ControlNet auto-detects the control type from the image, so a depth map needs no
preprocessor; feed your Blender pass straight in. Canny/MLSD also work if you feed those instead.

## 4. ControlNet details

Everything needed is included: the **node** (`comfyui-flux2fun-controlnet`, baked in), the
**model** (auto-downloaded to `/workspace/models/controlnet/`), and the **workflow** (section 3).
The ControlNet loads via the pack's own *Load Flux2 Fun ControlNet* node (ComfyUI's native
`ControlNetLoader` rejects this file — that's expected, the bundled workflow already uses the
correct node).

Set `DOWNLOAD_CONTROLNET=0` to skip the ControlNet download (t2i only). To try the newer
`-2602` checkpoint, add via `PROVISION_URLS`:
```
PROVISION_URLS="https://huggingface.co/alibaba-pai/FLUX.2-dev-Fun-Controlnet-Union/resolve/main/models/Personalized_Model/FLUX.2-dev-Fun-Controlnet-Union-2602.safetensors|controlnet/FLUX.2-dev-Fun-Controlnet-Union-2602.safetensors"
```

## 5. Adding LoRAs (later)

Drop `.safetensors` into `/workspace/models/loras/` (or via `PROVISION_URLS`). Remember to
load them with an **architecture-aware / pipeline-aligned loader**, not the generic one, or
FLUX.2 LoRAs may not apply correctly.

## Reproducible rebuilds

To pin ComfyUI to an exact commit (so a rebuild can never drift), uncomment the `build-args`
block in the workflow and set `COMFYUI_REF=<commit-sha>`.

## Notes

- FLUX.2 [dev] is under the FLUX.2 Non-Commercial License. Fine for private/experimental use;
  commercial use needs a separate agreement with Black Forest Labs.
- Base CUDA image tag is a build arg (`CUDA_IMAGE`) — change it if your target driver needs a
  different CUDA.
