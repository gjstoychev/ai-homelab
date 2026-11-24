# Journal

Every step in order: why, the exact command, expected vs actual, verdict. Failed attempts stay in.

## Decisions (2026-11-24)

- **Side benchmark, not a lab.** Closest planned lab: Lab 7 (fitting beyond VRAM).
- **Build from the v1.0.0 tag, natively.** v1.0.0 (2026-11-13) is the first release with semantic versioning; building from the tag gives a known commit, the GPU architecture of these cards and the NCCL of our choice (the board-swap benchmark showed that NCCL 2.25.1 crashes tensor split on these cards and 2.32.6 works).
- **CUDA 13.0, not 13.2.** The driver is 580.178.04 (Ubuntu's `nvidia-driver-580-server-open`), which supports CUDA up to 13.0. A driver upgrade is Lab 1's driver work and would change two things at once.
- **Toolchain as an Ansible role (`llama_cpp`), build as a user script** (`scripts/build-llamacpp.sh`). Nothing is installed into `/usr/local/lib`, so llama.cpp and Ollama (which ships its own ggml libraries in `/usr/local/lib/ollama/`) cannot load each other's libraries. NVIDIA's repository is pinned below Ubuntu so it cannot replace the driver's libraries.
- **Ollama disabled at boot** (`ollama_service_enabled: false`): it stays installed and is started by hand when needed. Both engines compete for the same VRAM and RAM; this model needs all of it.
- **Model download with `hf` from pipx** (`pipx install huggingface_hub`), pinned to a repository commit, not `pip --break-system-packages`.
- **To check before downloading:** the IQ3_XXS size differs between repositories (79.2 GiB in one, 88 GB in another). 32 GB of VRAM plus 62 GiB of RAM leave little room; the real size of the files in the chosen repository decides whether it fits.
- **Step 2, the tuner, is a script, not a flag.** A Python script in the llama.cpp repository (`docs/moe-cache.md`) that calculates the recommended cache size and CPU share for the machine. Its usage and the flags its output maps to are read from `docs/moe-cache.md` of the v1.0.0 checkout after the build; its full output goes into the journal. Its Python dependencies go into a venv inside `~/llama.cpp/v1.0.0/`, never into system Python.
