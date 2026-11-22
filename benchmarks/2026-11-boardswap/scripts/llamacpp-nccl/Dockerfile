# The pinned llama.cpp image (build 12464) with a newer NCCL, nothing else
# changed. Reason: `-sm tensor` crashes with the bundled NCCL 2.25.1 on RTX 5060
# Ti (sm_120): it requests 82240 B shared memory per block, the GPU allows 79856
# (journal step 14d). Build once before the swap and keep the image.
#
# The newest libnccl2 built for CUDA 12 in the image's NVIDIA apt repo is
# installed; the version goes to /nccl-version.txt. The ldd lines in the build
# log show which libnccl llama.cpp's CUDA backend loads, before and after.
FROM ghcr.io/ggml-org/llama.cpp@sha256:962077c3231fe2005da07be469136c25222b4d48434e98634bd20fa9cc1fc949

RUN set -eu; \
    echo "== before"; \
    ldd /app/libggml-cuda.so | grep -i nccl || echo "no dynamic libnccl"; \
    dpkg -l | grep -i nccl || echo "no nccl package"; \
    apt-get update; \
    v=$(apt-cache madison libnccl2 | awk '{print $3}' | grep '+cuda12' | head -n1); \
    echo "== installing libnccl2=$v"; \
    apt-mark unhold libnccl2 || true; \
    apt-get install -y --no-install-recommends --allow-change-held-packages \
      "libnccl2=$v"; \
    rm -rf /var/lib/apt/lists/*; \
    echo "libnccl2 $v" > /nccl-version.txt; \
    echo "== after"; \
    ldd /app/libggml-cuda.so | grep -i nccl || echo "no dynamic libnccl"; \
    dpkg -l | grep -i nccl
