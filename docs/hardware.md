# Hardware

Two nodes on the same LGA1700 platform (Z690 chipset, 13th/14th gen Intel). Both RTX 5060 Ti cards are installed in `formula`. `hero` is being rebuilt and is not used by any lab yet.

## formula — GPU compute node

| Component | Model |
|---|---|
| Motherboard | ASUS ROG Maximus Z690 Formula (BIOS 4101) |
| CPU | Intel Core i7-14700 |
| RAM | 64 GB (2×32 GB) Corsair Vengeance RGB DDR5-6000 CL40 (CMH64GX5M2D6000Z40) |
| GPU 0 | MSI GeForce RTX 5060 Ti 16 GB — PCIe 5.0 x8, CPU lanes (port 00:01.0) |
| GPU 1 | MSI GeForce RTX 5060 Ti 16 GB — PCIe 5.0 x8, CPU lanes (port 00:01.1; planned to move to `hero`) |
| System disk | Samsung PM9A1 512 GB NVMe M.2 |
| PSU | Fractal Design Ion+ 760W Platinum |
| Cooling | NZXT Kraken 280 RGB White |
| Case | NZXT H9 Flow (2023) |

Both GPUs share the CPU's PCIe 5.0 x16 lanes, split x8/x8, so the two slots are equal. There is no NVLink on this card and the driver reports no peer-to-peer support between the cards (`nvidia-smi topo -p2p r`: "chipset not supported"), so all GPU-to-GPU traffic goes through host memory. Idle links train down to 2.5 GT/s for power saving, so check `LnkSta` under load.

Firmware state: Intel's default CPU power limits (PL1 65 W, PL2 219 W), Resizable BAR on, console on the CPU's iGPU (UHD 770), both GPUs free for compute.

## hero — second node (planned, not in the labs yet)

Rebuild in progress: the board and CPU are on order. The other components come from the previous second node.

| Component | Model |
|---|---|
| Motherboard | ASUS ROG Maximus Z690 Hero |
| CPU | Intel Core i5-13400 (with iGPU, UHD 730) |
| RAM | 32 GB (2×16 GB) Corsair Vengeance RGB White DDR5-6000 CL36 (CMH32GX5M2E6000C36W) |
| GPU | None (currently); MSI GeForce RTX 5060 Ti 16 GB after the move from `formula` |
| System disk | Samsung PM9A1 512 GB NVMe M.2 |
| PSU | Seasonic G12-GM 650W 80 PLUS Gold |
| Cooling | NZXT Kraken X63 RGB (RL-KRX63-R1) |
| Case | NZXT H510 Elite |

To be filled in when it is built: BIOS version, slot wiring, NICs, firmware settings.

## GPU topology: scale-up vs scale-out

The same two RTX 5060 Ti cards will be tested in two topologies:

| | Current: single-node multi-GPU (scale-up) | Planned: multi-node, one GPU per node (scale-out) |
|---|---|---|
| Layout | 2× RTX 5060 Ti in `formula` | 1× RTX 5060 Ti in `formula`, 1× in `hero` |
| GPU-to-GPU interconnect | PCIe through host memory (2× Gen5 x8, CPU lanes), no NVLink, no P2P | Ethernet between the nodes |
| Typical model split | Tensor parallelism (TP=2) or layer split within one process | Pipeline parallelism (PP=2) across nodes (e.g. vLLM with Ray, llama.cpp RPC) |
| Total VRAM | 32 GB | 32 GB |

The comparison measures what the interconnect costs: tensor parallelism exchanges activations on every layer and needs a fast link, while pipeline parallelism only passes activations at the stage boundary and tolerates a slower network at the price of pipeline bubbles. Both topologies have the same total VRAM, so differences in throughput and latency come from the interconnect and the parallelism strategy, not from capacity.

## Name history

Older results, guides and the board-swap benchmark use the old host names.

| Now | Before | Change |
|---|---|---|
| `formula` | `z790` | 2026-11: NZXT N7 Z790 replaced by ASUS ROG Maximus Z690 Formula; GPU1 moved from a chipset Gen4 x4 slot to CPU lanes, Gen5 x8. Measured before and after: `benchmarks/2026-11-boardswap/`. |
| `hero` | `b760` | 2026-11: ASRock B760 Pro RS + i5-14400F to be replaced by ASUS ROG Maximus Z690 Hero + i5-13400. |
