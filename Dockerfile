# syntax=docker/dockerfile:1

# CUDA 12.4 base = FP8 (fp8_e4m3fn) support on Ada/Hopper (L40S / H100).
# Override with --build-arg CUDA_IMAGE=... if you need a different CUDA.
ARG CUDA_IMAGE=nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04
FROM ${CUDA_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1 \
    COMFYUI_DIR=/opt/ComfyUI \
    HF_HUB_ENABLE_HF_TRANSFER=0

# --- System deps ---
RUN apt-get update && apt-get install -y --no-install-recommends \
      git wget curl ca-certificates \
      python3 python3-pip python3-venv \
      libgl1 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python3 /usr/bin/python

# --- PyTorch (CUDA 12.4, FP8-capable) ---
RUN pip install --upgrade pip && \
    pip install torch torchvision torchaudio \
      --index-url https://download.pytorch.org/whl/cu124

# --- ComfyUI ---
# Pin a specific commit/tag with --build-arg COMFYUI_REF=<sha> for full reproducibility.
ARG COMFYUI_REF=master
RUN git clone https://github.com/comfyanonymous/ComfyUI.git ${COMFYUI_DIR} && \
    cd ${COMFYUI_DIR} && git checkout ${COMFYUI_REF} && \
    pip install -r requirements.txt

# --- Custom nodes: Manager (for adding ControlNet nodes later) + ControlNet preprocessors ---
RUN cd ${COMFYUI_DIR}/custom_nodes && \
    git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Manager.git && \
    git clone --depth 1 https://github.com/Fannovel16/comfyui_controlnet_aux.git && \
    pip install -r ComfyUI-Manager/requirements.txt && \
    pip install -r comfyui_controlnet_aux/requirements.txt

# --- Helpers ---
RUN pip install huggingface_hub

# --- Entrypoint ---
COPY docker/start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 8188
CMD ["/start.sh"]
