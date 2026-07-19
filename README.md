# runpod-flux2

Lean **ComfyUI + FLUX.2 [dev] FP8** image for RunPod, built via GitHub Actions.

The image stays small (~a few GB): **models are not baked in** — they download into the pod's
**ephemeral disk** on each start (fast, parallel), so there's no persistent volume and no idle
storage cost. LoRAs are intentionally left out for now; a depth-ControlNet archviz workflow is
bundled and ready.

## What's inside

- CUDA 12.4 + PyTorch (cu124) — native **FP8** on Ada/Hopper (L40S / H100)
- ComfyUI (native FLUX.2 nodes) + ComfyUI-Manager + ControlNet preprocessors
- **FLUX.2 Fun ControlNet** node (`comfyui-flux2fun-controlnet`) baked in — depth / canny / MLSD
- **Bundled turnkey workflow** `flux2-depth-archviz` — depth pass in, rendered design out
- First-boot provisioning of:
  - `diffusion_models/flux2_dev_fp8mixed.safetensors`
  - `text_encoders/mistral_3_small_flux2_bf16.safetensors` (bf16 = best prompt adherence)
  - `vae/flux2-vae.safetensors`
  - `controlnet/FLUX.2-dev-Fun-Controlnet-Union-2602.safetensors`

### Important: the ControlNet has its own loader

The official base FLUX.2 workflow is text-to-image + multi-reference editing — it does **not**
do proper depth-map ControlNet. For strict geometry from your Blender depth pass, use the
**flux2fun** nodes: load the ControlNet with the node pack's **own "Load ControlNet" node**
(ComfyUI's native `ControlNetLoader` rejects this file). Ready-to-use depth/canny workflows
ship in the node's `examples/` folder — start there. Depth conditioning scale ~**0.65–0.80**.

> This node is a fairly new community wrapper (confirmed working on fp8). Run a **mini-test on
> 2–3 Blender depth passes first** to confirm geometry adherence before committing the full pipeline.

## 1. Build (GitHub Actions → Docker Hub)

1. Push this repo to GitHub.
2. The workflow in `.github/workflows/build.yml` runs on every push to `main` (and on tags / manual dispatch) and pushes to **Docker Hub** as `docker.io/<your-user>/runpod-flux2:latest`. Add two repo secrets first: **`DOCKERHUB_USERNAME`** and **`DOCKERHUB_TOKEN`** (Settings → Secrets and variables → Actions). The token needs **Read & Write**.
3. On Docker Hub, set the repository **Public** (simplest — RunPod pulls without credentials), or keep it private and add Docker Hub credentials to the RunPod template.

## 2. RunPod template (no network volume)

You're running **without a persistent volume** — nothing is stored while the pod is off, so you
pay zero idle storage. The tradeoff: models re-download into the pod's ephemeral disk on **every
start** (fast, parallel via aria2). Create a **Pod template** with:

| Setting | Value |
|---|---|
| Container image | `docker.io/<your-user>/runpod-flux2:latest` |
| **Container disk** | **~150 GB** (holds ~85 GB models + scratch + renders — this is ephemeral) |
| Network volume | **none** |
| Expose HTTP port | **8188** |
| GPU | **L40S (48 GB, FP8)** or **H100 (80 GB)** — *not A100 (no native FP8)* |

> ⚠️ **Nothing persists.** Models, generated images, and any installed nodes vanish when the pod
> is terminated. **Download your renders before stopping the pod.** (The bundled workflow is baked
> into the image, so it reappears automatically each start.)

### Environment variables (all optional)

| Var | Default | Purpose |
|---|---|---|
| `TEXT_ENCODER` | `bf16` | Set to `fp8` to **roughly halve the encoder download** (~48 GB → ~24 GB) and cut startup time, at a small prompt-adherence cost. |
| `HF_TOKEN` | — | **Not needed.** Both mirrors (Comfy-Org, alibaba-pai) are public/non-gated. Only set this if you switch a source to a gated repo. |
| `DOWNLOAD_CONTROLNET` | `1` | `0` skips the ControlNet download (t2i only). Default pulls the **`-2602`** checkpoint (authors' recommended, better-performing version). |
| `COMFY_ARGS` | `--listen 0.0.0.0 --port 8188 --fast` | Override launch flags. |
| `PROVISION_URLS` | — | Extra downloads, space-separated `url\|subdir/filename`. |

> **First (and every) boot downloads the models** — ~85 GB with the bf16 encoder, ~60 GB with
> `TEXT_ENCODER=fp8`. Parallel download keeps the wait short on RunPod's fast network. Generation
> starts automatically once downloads finish.

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
**model** (the recommended **`-2602`** checkpoint, auto-downloaded to
`/workspace/models/controlnet/`), and the **workflow** (section 3). The ControlNet loads via the
pack's own *Load Flux2 Fun ControlNet* node (ComfyUI's native `ControlNetLoader` rejects this
file — that's expected, the bundled workflow already uses the correct node).

Set `DOWNLOAD_CONTROLNET=0` to skip the ControlNet download (t2i only).

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
