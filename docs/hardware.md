# Hardware

Two nodes on the same LGA1700 platform (14th gen, Raptor Lake Refresh). Both RTX 5060 Ti cards are currently installed in `z790`; `b760` has no GPU and is powered off.

## z790 — GPU compute node

| Component | Model |
|---|---|
| Motherboard | NZXT N7 Z790 |
| CPU | Intel Core i7-14700 |
| RAM | 64 GB (2×32 GB) Corsair Vengeance RGB DDR5-6000 CL40 (CMH64GX5M2D6000Z40) |
| GPU 0 | MSI GeForce RTX 5060 Ti 16 GB — PCIe 5.0 x8, CPU lanes |
| GPU 1 | MSI GeForce RTX 5060 Ti 16 GB — PCIe 4.0 x4, chipset lanes (planned to move to `b760`) |
| System disk | Samsung PM9A1 512 GB NVMe M.2 |
| PSU | Fractal Design Ion+ 760W Platinum |
| Cooling | NZXT Kraken 280 RGB White |
| Case | NZXT H9 Flow (2023) |

The two GPU slots are not equal: GPU 0 is wired to the CPU, GPU 1 sits behind the chipset with half the lanes and one PCIe generation lower, and shares the chipset's DMI uplink with other chipset-attached devices. There is no NVLink on this card, so all GPU-to-GPU traffic goes over PCIe. Both cards are PCIe 5.0 x8 devices; the values above are what each slot provides. Idle links train down to 2.5 GT/s for power saving, so check `LnkSta` under load.

## b760 — control node

| Component | Model |
|---|---|
| Motherboard | ASRock B760 Pro RS |
| CPU | Intel Core i5-14400F (no iGPU) |
| RAM | 32 GB (2×16 GB) Corsair Vengeance RGB White DDR5-6000 CL36 (CMH32GX5M2E6000C36W) |
| GPU | None (currently); MSI GeForce RTX 5060 Ti 16 GB after the move from `z790` |
| System disk | Samsung PM9A1 512 GB NVMe M.2 |
| PSU | Seasonic G12-GM 650W 80 PLUS Gold |
| Cooling | NZXT Kraken X63 RGB (RL-KRX63-R1) |
| Case | NZXT H510 Elite |

## GPU topology: scale-up vs scale-out

The same two RTX 5060 Ti cards will be tested in two topologies:

| | Current: single-node multi-GPU (scale-up) | Planned: multi-node, one GPU per node (scale-out) |
|---|---|---|
| Layout | 2× RTX 5060 Ti in `z790` | 1× RTX 5060 Ti in `z790`, 1× in `b760` |
| GPU-to-GPU interconnect | PCIe (x8 CPU + x4 chipset), no NVLink | Ethernet between the nodes |
| Typical model split | Tensor parallelism (TP=2) or layer split within one process | Pipeline parallelism (PP=2) across nodes (e.g. vLLM with Ray, llama.cpp RPC) |
| Total VRAM | 32 GB | 32 GB |

The comparison measures what the interconnect costs: tensor parallelism exchanges activations on every layer and needs a fast link, while pipeline parallelism only passes activations at the stage boundary and tolerates a slower network at the price of pipeline bubbles. Both topologies have the same total VRAM, so differences in throughput and latency come from the interconnect and the parallelism strategy, not from capacity.
