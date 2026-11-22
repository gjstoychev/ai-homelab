## Findings

### Before the swap (2026-11-19)

Two identical RTX 5060 Ti 16 GB (same VBIOS, same 180 W limit, same VRAM
bandwidth). GPU0 on CPU lanes, GPU1 behind the chipset. No peer-to-peer
between the cards (driver reports "chipset not supported"), so all GPU-to-GPU
traffic goes through host memory.

**Bus.** Under load GPU0 runs at Gen5 x8 and GPU1 at Gen4 x4. Measured: GPU0
20.3 GB/s host -> GPU, GPU1 7.2 GB/s, a gap of ~2.8x rather than the 4x on
paper (GPU0 reaches only ~64 % of its link's theoretical rate; the link is not
the limit). GPU1 uses ~91 % of its x4 link. With both GPUs busy at once, GPU1
drops 19-27 %, GPU0 only 5-6 %. GPU1's host latency is twice GPU0's (1191 vs
612 ns).

**One card or layer split: the slot does not matter.** GPU0 and GPU1 generate
within 0.6 % of each other, and layer split across both cards is within 1 % of
one card. Once the model is in VRAM, almost nothing crosses the bus.

**Tensor split: where the bus matters.** llama.cpp's tensor split (each card
holds half of every weight matrix, synced through host memory every layer)
makes generation 39-66 % faster on dense models, more for larger models (32B:
20.3 -> 33.6 t/s, ~83 % of the ideal 2x). It needed a newer NCCL than the
official llama.cpp image ships (2.25.1 crashes on these cards). The missing
17-31 % to the ideal is sync cost over the bus, which is what the x8/x8 board
can change. MoE (Qwen3 30B-A3B): tensor split is ~10 % slower than layer split.

**MTP speculative decoding** (Qwen3.8 27B): tensor split + MTP reaches 73.9
t/s, 3.1x plain layer split (24.2). Acceptance ~50 % on the benchmark text.

**Engines.** Ollama 0.32.14 runs a bundled llama.cpp `llama-server`; with the
same options it generates at the same speed as llama.cpp (dense models -2.1 to
+0.5 %). Its two-card mode is layer split only (no tensor split), it enables
MTP by itself (27B: 42.8 t/s), and it loads models 3-8x slower (15-33 s vs
2-12 s). Details: `engines.md`.

**What to watch after the swap** (GPU1 moves to CPU lanes, x8):

- GPU1 bandwidth and latency (nvbandwidth): expected close to GPU0.
- The both-GPUs-at-once drop of GPU1: if it disappears, the chipset path was
  the cause.
- Tensor split and tensor + MTP: the only configurations where the bus is in
  the hot path; this is where a difference in t/s should appear.
- One card and layer split: expected unchanged (a control).

### After the swap (2026-11-22)

ASUS ROG Maximus Z690 Formula (BIOS 4101): both GPUs on CPU lanes, Gen5 x8
each (ports 00:01.0 and 00:01.1). Other differences, all checked: kernel
7.0.0-43 instead of -38 (automatic security update), Intel's default CPU
power limits (PL1 65 W, PL2 219 W instead of 241/241 W; the CPU's 28-second
average never reached 65 W), display on the CPU's iGPU instead of GPU0. RAM
speed (6000 MT/s), Resizable BAR, driver, images and models are identical.

**Bus.** GPU1 now matches GPU0: 19.4 GB/s host -> GPU (before 7.2, +172 %),
16.6 GB/s GPU -> host (+129 %), latency 612 ns (before 1191, -49 %). With
both GPUs copying at once the total stays at ~25 GB/s, as before; the drop was
not the chipset but a shared limit on the host side, and the split is still
uneven (16.8 / 8.6 GB/s).

**One card and layer split: unchanged.** Every configuration without tensor
split, in all three engines, is within about ±1 % of before (one outlier
+7.5 %). That also shows that the kernel, the power limits and the moved
display had no measurable effect.

**Tensor split: the board pays off here.** Generation +7 to +21 %, prompt
processing +16 to +39 %. Tensor split now gets 79-88 % of the ideal 2x on
dense models (before 69-83 %): Llama 3.1 8B 118.8 -> 135.0 t/s, Qwen3 32B
33.6 -> 35.9 t/s. Prompt processing with tensor split is now faster than one
card for every model (+22 to +49 %; before, small models were 8-12 % slower).
The MoE model gains most (+21 %): tensor split now beats layer split for it
(165.5 vs 154.4 t/s; before it was 10 % slower).

**MTP.** Qwen3.8 27B with tensor split + MTP: 73.9 -> 77.8 t/s (+5 %), now
3.2x plain layer split.

**Bottom line.** For one card or layer split, a chipset x4 slot costs nothing
measurable. It matters only when the cards talk to each other every layer:
llama.cpp's tensor split. There the x8/x8 board gains 7-21 % generation and
16-39 % prompt processing, and makes tensor split the fastest generation
mode for every model tested, including MoE. (MoE prompt processing in
llama-server is the exception: layer split stays 10 % ahead there.)
