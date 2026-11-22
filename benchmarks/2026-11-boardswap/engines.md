# Ollama vs llama.cpp on 2x RTX 5060 Ti

Collected along the board swap benchmark: which engine gets the most out of two
16 GB cards, and what each one costs in practice. Speed numbers come from the
benchmark steps (see `journal.md`); everything here says where it comes from.
Status: complete for both boards (before: x8/x4 with chipset link; after:
x8/x8 on CPU lanes); recommendation for the current hardware; open points at
the end.

## The key fact: Ollama is llama.cpp

Ollama 0.32.14 serves every model tested here by starting a bundled llama.cpp
`llama-server` (build "1 (7e4c0a968)") with fixed options: `-c 4096 -np 1
--flash-attn on -b 512 -ub 512 --context-shift` (journal 16b). With
`OLLAMA_SCHED_SPREAD=1` it only makes both GPUs visible, and llama.cpp's
default layer split does the rest.

So the comparison is really: llama.cpp with Ollama's defaults and
conveniences, against llama.cpp with options chosen by hand (most importantly
tensor split, which Ollama does not offer).

## Versions tested

| | Ollama | llama.cpp |
|---|---|---|
| Version | 0.32.14 (host service and Docker image), bundled llama-server commit 7e4c0a968 | build 12464 (commit d3c3e242c), official `full-cuda` image |
| Changes | none | NCCL 2.25.1 replaced by 2.32.6 (`scripts/llamacpp-nccl/Dockerfile`) |
| Runs as | hardened systemd service (homelab); Docker for the benchmark | Docker |

Weights and cache, identical in both engines: the same GGUF files (Q4_K_M;
Llama 3 8B Q4_0), KV cache f16 for K and V (llama-bench records it per run,
Ollama logs it per load, llama-server uses the default), flash attention on,
4096-token context. Ollama's own default context would be 32K (16a).

## Multi-GPU modes

| Mode | What it does | PCIe traffic | Ollama | llama.cpp |
|---|---|---|---|---|
| single card | whole model on one card | none during generation | yes | yes (`--gpus device=N`) |
| layer split | each card holds whole layers; cards take turns | small (activations at the split point) | yes (`OLLAMA_SCHED_SPREAD=1`, or automatically when a model does not fit one card) | yes (`-sm layer`, default) |
| row split | weight matrices split by rows | high | no | listed, but fails in build 12464: "device CUDA0 does not support split buffers" (journal 14, 14b) |
| tensor split | tensor parallelism; each card holds half of every weight matrix; allreduce via NCCL | high | no | yes (`-sm tensor`), only with a newer NCCL on sm_120 (journal 14c-14f) |

Only llama.cpp can split the weight matrices themselves. That is the mode where
two cards can be faster than one, not just bigger.

## Speed, before the swap

Tokens per second, GPU1 on chipset x4. Full table for every model, scenario
and engine: `results/tps-before.md`. llama.cpp is measured twice:
llama-bench (synthetic pp512/tg128) and llama-server (same client, prompt and
server options as Ollama, so the llama-server and Ollama columns compare 1:1).
Mean of 5.

| Model | Scenario | tg llama-bench | tg llama-server | tg Ollama | pp llama-server | pp Ollama |
|---|---|---:|---:|---:|---:|---:|
| Llama 3.1 8B | 1 card (GPU0) | 84.6 | 82.7 | 82.6 | 3761 | 3532 |
| Llama 3.1 8B | 2 cards, layer / spread | 84.0 | 82.2 | 81.8 | 4008 | 3746 |
| Llama 3.1 8B | 2 cards, tensor | **118.8** | **116.6** | not available | 3413 | not available |
| Qwen3 14B | 1 card (GPU0) | 44.7 | 44.1 | 44.2 | 2022 | 1896 |
| Qwen3 14B | 2 cards, layer / spread | 44.5 | 43.8 | 44.0 | 2143 | 2004 |
| Qwen3 14B | 2 cards, tensor | **69.3** | **68.6** | not available | 2023 | not available |
| Qwen3.8 27B | 2 cards, layer | 24.2 | 24.2 | - | 827 | - |
| Qwen3.8 27B | 2 cards, tensor | 37.9 | 37.8 | not available | 816 | not available |
| Qwen3.8 27B | 2 cards, layer + MTP | - | 51.8 | 42.8 (Ollama's default) | 811 | 687 |
| Qwen3.8 27B | 2 cards, tensor + MTP | - | **73.9** | not available | 786 | not available |
| Qwen3 32B | 2 cards, layer / spread | 20.3 | 20.1 | 20.1 | 926 | 877 |
| Qwen3 32B | 2 cards, tensor | **33.6** | **33.5** | not available | 1039 | not available |
| Qwen3 30B-A3B (MoE) | 2 cards, layer / spread | 152.5 | 144.7 | **155.0** | 4016 | 3023 |
| Qwen3 30B-A3B (MoE) | 2 cards, tensor | 136.8 | 131.5 | not available | 3124 | not available |
| TranslateGemma 4B | 1 card (GPU0) | does not load | does not load | 124.3 | - | 5378 |

Load time from `docker run` / model request until ready (journal 16b, 17):

| | llama-server | Ollama |
|---|---:|---:|
| 8B / 14B models | 2-5 s | 15-21 s |
| 27B / 30B / 32B models | 4-12 s | 24-33 s |

### Findings

- Same options, same speed: Ollama and llama-server generate within -2.1 to
  +0.5 % of each other on dense models (median -0.2 %); Ollama's prompt
  processing is 2-7 % lower. On the MoE model Ollama generates 7 % faster but
  processes prompts 25 % slower (it bundles a different llama.cpp build).
- Layer split gives no speed in either engine: within 1 % of one card. Two
  cards in layer mode only buy memory for bigger models.
- Tensor split (llama.cpp only) is the speed lever for dense models: +39 to
  +55 % generation on 8B/14B, +56 % on the 27B, +66 % on the 32B (20.3 -> 33.6
  t/s, ~83 % of the ideal 2x). Prompt processing with tensor split changes
  with size: -10 % (8B), ~0 % (14B), +8 % (27B), +20 % (32B) in llama-bench.
- MoE (Qwen3 30B-A3B, ~3B active per token): tensor split is ~10 % slower than
  layer split. Ollama's spread is as fast as llama.cpp's best mode here.
- MTP speculative decoding (Qwen3.8 27B, ~50 % of drafted tokens accepted):
  layer + MTP 51.8 t/s, tensor + MTP 73.9 t/s, 3.1x plain layer split.
  Ollama turns MTP on by itself (42.8 t/s) but cannot combine it with tensor
  split. Acceptance depends on the text; the benchmark prompt is repetitive,
  so real chats may gain less. The ranking of the modes should hold.
- Load times: llama-server is 3-8x faster to get a model ready.

Recommendation per use case: see the next section.

## Speed after the swap (x8/x8, current hardware)

Same models, images and scripts; both GPUs on CPU lanes, Gen5 x8 (journal
"Part 2 after the swap"). Full tables: `results/tps-after.md`, before vs
after: `results/summary.md`. Generation (tg) and prompt processing (pp), t/s.

| Model | Scenario | tg llama-server | tg Ollama | pp llama-server | pp Ollama |
|---|---|---:|---:|---:|---:|
| Llama 3.1 8B | 1 card (GPU0) | 82.4 | 81.8 | 3745 | 3498 |
| Llama 3.1 8B | 2 cards, layer / spread | 82.3 | 82.2 | 4023 | 3751 |
| Llama 3.1 8B | 2 cards, tensor | **130.3** | not available | **4518** | not available |
| Qwen3 14B | 1 card (GPU0) | 43.9 | 44.0 | 2010 | 1883 |
| Qwen3 14B | 2 cards, layer / spread | 43.9 | 44.0 | 2150 | 2014 |
| Qwen3 14B | 2 cards, tensor | **74.3** | not available | **2613** | not available |
| Qwen3.8 27B | 2 cards, layer | 24.2 | - | 838 | - |
| Qwen3.8 27B | 2 cards, tensor | 40.4 | not available | 986 | not available |
| Qwen3.8 27B | 2 cards, layer + MTP | 52.1 | 42.8 (Ollama's default) | 824 | 701 |
| Qwen3.8 27B | 2 cards, tensor + MTP | **77.8** | not available | 951 | not available |
| Qwen3 32B | 2 cards, layer / spread | 20.1 | 20.1 | 927 | 879 |
| Qwen3 32B | 2 cards, tensor | **35.8** | not available | **1276** | not available |
| Qwen3 30B-A3B (MoE) | 2 cards, layer / spread | 143.8 | 156.4 | **4023** | 3032 |
| Qwen3 30B-A3B (MoE) | 2 cards, tensor | **158.2** | not available | 3622 | not available |

What the board changed for the engine question:

- Nothing for Ollama, and nothing for llama.cpp without tensor split: every
  one-card and layer-split result is within about ±1 % of before.
- Tensor split, llama.cpp's advantage, grew: +7 to +21 % generation and +16
  to +39 % prompt processing over the x8/x4 board. It now reaches 79-88 % of
  the ideal 2x on dense models and speeds up prompt processing too (before,
  small models processed prompts 8-12 % slower with it).
- MoE: tensor split now generates faster than layer split (llama-server
  158.2 vs 143.8; before 131.5 vs 144.7), on par with Ollama (156.4). For MoE
  prompt processing, llama-server's layer split stays best (4023 t/s, Ollama
  3032).

## Recommendation (current hardware, x8/x8)

Measured on 2x RTX 5060 Ti 16 GB, both on CPU lanes (Gen5 x8), 4K context,
one request at a time. Sources in brackets: journal entries and
`results/tps-after.md`. The before-swap numbers are in the sections above.

### Short answer

To get the most tokens per second out of two cards, use llama.cpp's
`llama-server` with tensor split, plus MTP speculative decoding for models
that have an MTP head. Compared with Ollama on the same cards: +59 % on
Llama 3.1 8B (130.3 vs 82.2 t/s), +69 % on Qwen3 14B (74.3 vs 44.1), +78 % on
Qwen3 32B (35.8 vs 20.1), +82 % on Qwen3.8 27B (77.8 vs 42.8, both with MTP),
and models load 3-8x faster (17). On the MoE model the two are even in
generation (158.2 vs 156.4). Ollama is the same engine underneath and just as
fast where it can do the same thing (one card, layer split), and it manages
models and MTP for you. The price of llama.cpp is configuration: options per
model, a custom image for tensor split on these cards, and no automatic model
management. On the x8/x4 board the same advice held, with a smaller margin
(+40 to +73 %).

### Per use case

| Use case | Best here | Numbers (t/s, generation unless noted; Ollama: its best mode) | Not measured |
|---|---|---|---|
| Chat with a dense model that fits one card (8B-14B), e.g. Qwen3 14B | llama-server, tensor split | Qwen3 14B: 74.3 vs 44.1 in Ollama (+69 %); Llama 3.1 8B: 130.3 vs 82.2 (+59 %) | 32K context; both cards are taken by one model |
| Dense models that need both cards (27B, 32B) | llama-server, tensor split (+ MTP if available) | Qwen3 32B: 35.8 vs 20.1 (+78 %); Qwen3.8 27B: 77.8 with tensor + MTP vs 42.8 in Ollama (+82 %) | MTP with real chat text (~50 % acceptance on the benchmark text) |
| MoE models (Qwen3 30B-A3B) | either for chat; llama-server layer split for long prompts | tg: llama-server tensor 158.2, Ollama 156.4, llama-server layer 143.8; pp: llama-server layer 4023, tensor 3622, Ollama 3032 | prompts beyond ~540 tokens |
| Long prompts (documents, RAG), dense models | llama-server, tensor split | pp now higher with tensor split than one card: Llama 3.1 8B 4518 vs 3745 (+21 %), Qwen3 14B 2613 vs 2010 (+30 %); Ollama 2-7 % below llama-server in the same mode | prompts beyond ~540 tokens, 32K context |
| Many models, frequent switching | Ollama (convenience) | Ollama loads in 15-33 s, llama-server in 2-12 s (both boards) | llama-server behind a switching proxy (e.g. llama-swap) |
| Two models at once (e.g. chat + embeddings) | one model per card, either engine | GPU0 and GPU1 within 1 % of each other on both boards | tensor-split chat model plus an embedding model in the remaining VRAM |
| Models Ollama converted itself | Ollama | translategemma loads only in Ollama (14, 16b) | other Ollama-converted models |

### What a switch would mean for this homelab

- Ghostwheel talks to Ollama's native API: `/api/chat` for generation,
  `/api/embed` for embeddings, `/api/tags` to check that a model's weights
  blob matches the one that passed its qualification (ghostwheel docs). Its
  model interface was built not to know where the model lives, so a switch is
  an adapter, not a rewrite: llama-server speaks the OpenAI-style
  `/v1/chat/completions` and `/v1/embeddings`. The `/api/tags` blob check
  needs a replacement; with llama-server the GGUF path (= the blob) is fixed
  in its start options. Whether this llama-server build also offers
  Ollama-style endpoints was not checked.
- Ghostwheel loads `qwen3:14b` with a 32K context; all numbers here use 4K.
  Speed and VRAM use of tensor split at 32K are not measured yet.
- Tensor split on these cards needs the custom image (llama.cpp build 12464 +
  NCCL 2.32.6, `scripts/llamacpp-nccl/Dockerfile`). An official image update
  may fix the NCCL problem or break tensor split again (row split broke in
  this build); pin and re-test before upgrading.
- Options per model become our job: `-sm tensor` for generation (now also for
  MoE), layer split for MoE prompt-heavy use, `--spec-type draft-mtp` for
  models with an MTP head, context size. Ollama decides these itself (16a,
  16b).
- The Ollama service is hardened with systemd (lab 0b); a llama-server
  service needs the same treatment. It fits the roadmap: Lab 8 already plans
  a LiteLLM gateway with llama-server and vLLM backends, which also covers
  routing between models.

### Not measured yet

Long contexts (32K), several parallel requests, MTP acceptance on real chat
prompts, VRAM use per engine, stability over hours.

### For the blog post

> On two RTX 5060 Ti cards, Ollama and llama.cpp generate at the same speed,
> because Ollama runs llama.cpp underneath. The difference is what each one
> lets you do with the second card. Ollama can only stack layers across the
> cards: more memory, no extra speed. llama.cpp can split every weight matrix
> across both cards (tensor split): with both cards on CPU lanes (x8/x8) that
> is +59 to +78 % tokens per second on dense models, and with speculative
> decoding a 27B model went from 24 to 78 tokens per second. Tensor split is
> also the only place where the motherboard mattered: moving the second card
> from a chipset x4 slot to CPU lanes changed nothing for one card or layer
> split, but gave tensor split another 7-21 % in generation and 16-39 % in
> prompt processing. The cost of llama.cpp is setup: a newer NCCL than the
> official image ships, options per model, and no automatic model management.

## Practical differences

| | Ollama | llama.cpp |
|---|---|---|
| Model download and storage | `ollama pull`, own store with manifests | plain GGUF files; can read most of Ollama's blobs directly |
| Model compatibility | its bundled llama-server loads its own converted files, including translategemma | build 12464 cannot load Ollama's translategemma GGUF (`gemma3.attention.layer_norm_rms_epsilon` missing, journal 14) |
| Switching models | automatic load/unload per request | `llama-server` serves one model per process; switching needs an extra layer (e.g. a proxy such as llama-swap; not tested here) |
| Two models at once | possible, one per card | possible with one server per card; with tensor split one model takes both cards |
| Setup on these cards | worked out of the box | tensor split needed a newer NCCL than the official image ships, plus `--shm-size` in Docker |
| Defaults that matter | context sized from total VRAM (32K on 2x16 GB), flash attention off unless set, Vulkan on but CUDA used (journal 16a); MTP speculative decoding on for models that have it (16b) | everything set per run (`-c`, `-fa`, `-sm`, `--spec-type`) |
| Load time (until ready) | 15-21 s single-card models, 24-33 s large models (16b) | 2-5 s and 4-12 s (17) |
| Update risk | low for the modes it offers | the multi-GPU modes changed recently (row broken, tensor new); updates can fix or break them |

## Open points

- Unexplained: Ollama spread is ~6 % faster at prompt processing than Ollama
  on one card; llama.cpp layer split shows no such gain.
- MTP acceptance with real chat prompts (the benchmark prompt is repetitive).
- Answered after the swap: yes, tensor split gains 7-21 % generation and
  16-39 % prompt processing; nothing else changes.
- Why concurrent host copies stay at ~25 GB/s total on both boards
  (nvbandwidth "both at once"), with an uneven split between the ports.
- Not in the current plan, candidates for later: VRAM use per engine at the
  same context size; several parallel requests (llama-server slots vs
  `OLLAMA_NUM_PARALLEL`); long contexts; a model-switching proxy in front of
  llama-server.
