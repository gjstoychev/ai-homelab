# nvbandwidth (NVIDIA's bus bandwidth benchmark) for 2x RTX 5060 Ti (sm_120).
# Build once before the swap and keep the image; after the swap re-run the
# same image instead of rebuilding, so the binary is identical.
#
# NVBW_REF empty = newest release tag at build time. The chosen tag and commit
# are written to /nvbandwidth-version.txt.
FROM nvidia/cuda:13.0.0-devel-ubuntu24.04

ARG NVBW_REF=

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential ca-certificates cmake git libboost-program-options-dev \
 && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
    url=https://github.com/NVIDIA/nvbandwidth; \
    ref=${NVBW_REF:-$(git ls-remote --tags --refs --sort=-v:refname "$url" \
      | head -n1 | sed 's#.*refs/tags/##')}; \
    git clone --depth 1 --branch "$ref" "$url" /src; \
    git -C /src log -1 --format="nvbandwidth $ref %H %cs" \
      | tee /nvbandwidth-version.txt

WORKDIR /src
RUN cmake -B build -DCMAKE_CUDA_ARCHITECTURES=120 \
 && cmake --build build -j"$(nproc)" \
 && install -m 755 \
      "$(find build -maxdepth 2 -type f -name nvbandwidth -perm -u+x)" \
      /usr/local/bin/nvbandwidth

ENTRYPOINT ["/usr/local/bin/nvbandwidth"]
