# Redline audit — RX 6700 XT

This file records measured Project Redline work on `rx6700xt-adaptation`. It does
not claim a feature that the runtime does not implement.

## G0 — environment

| Item | Observed |
|---|---|
| CPU | AMD Ryzen 5 7500F, 6 physical cores / 12 logical CPUs |
| RAM | 31.6 GiB |
| GPU | AMD Radeon RX 6700 XT, PCI device `0x73DF`, 12 GB |
| Driver | AMD Adrenalin `32.0.21045.5002`, 2026-08-16 |
| OS | Windows 11 Pro 26200 x64 |
| Host target | `x86_64-pc-windows-gnu` because no MSVC linker is installed |
| Game build | `1.0.2.1 retail (Scarlett)`, BLAKE3 `b99f876b...39e93` |
| Console profile | Xbox Series X |

`PresentMon-x64.exe` is available through the AMD driver installation. RGP,
RMV, RGA, RRA and RGD are not installed, so no counter data from those tools is
claimed. The fork's own frame, transfer, memory, pipeline and streaming logs are
the primary evidence.

## G1 — build and cache

The diagnostics build succeeds with Rust 1.98.1 GNU. The focused `victory-hle`
tests and full `cargo check -p victory --features diagnostics` pass. The fork's
entire Rust tree is not `rustfmt --check` clean upstream; only touched files are
formatted and checked.

The shader warm-up scanned the complete 208.5 GiB data tree:

- before: 6,540 shader-cache files, 399.7 MiB
- command: `victory.exe shaders --jobs 6`
- duration: 348 s
- translated: 25,782
- rejected: 203
- after: 28,909 shader-cache files, 1,106 MiB

Rejected translation was dominated by 198 non-program DXIL containers. The
remaining five failed on descriptor data reads. None of these results is a
claim that every game shader is translated.

## Existing baseline before this audit

| Run | Result |
|---|---|
| WARP diagnostics | reached first-boot menus, intro and world transition |
| RX 6700 XT safe | 30 fps menus; 0-5 fps world preparation; reached world |
| RX 6700 XT fast/7900 profile | device removed `0x887A0007` after six seconds in world |
| RX 6700 XT stable, 25-minute launch | 3-5 fps world, peak 28.83 GiB private; RAM fell below 0.4 GiB; process exited after 14m34s monitored without a new VIctory crash record |

The long stable run therefore ended at the title's watchdog or normal process
termination, not in a fresh D3D12 crash recorded by VIctory. The distinction is
kept.

## G2-G4 — hot-cache diagnostic run

Cache-hot launch on 2026-11-25 23:51:

- menus: 29-30 fps, 33.3 ms/frame
- preparation in menus: 0.3-3.0 ms
- initial world transition: large texture backlog and 0-3 fps
- dedicated VRAM during the heavy scene: 8,830 MiB used of a 9,760 MiB budget
- shared memory used with the card: 8,270 MiB
- private process memory: about 24.6 GiB in the same scene
- pipeline creation had fallen to zero after the transition

A representative 325 ms frame reported:

| Component | Time |
|---|---|
| Frame preparation | 114.3 ms |
| Copies for preparation | 65.5 ms / 236.6 MiB |
| GPU | 80.5 ms |
| Copy back to title memory | 95.3 ms / 93.5 MiB |
| Texture refresh, all threads | 42.7 ms |
| Waiting for title-memory guards | 43.8 ms |
| Changing memory protections | 22.3 ms |
| Heap-view pass | 18.8 ms |

The 23,387 textures still waiting demonstrates that the critical path includes
residency and streaming, not only shader execution. The GPU was only about 22%
busy by the fork's submission clock in the sampled interval, while the
submitting thread and copyback work were busy. This is a CPU/copy/synchronization
problem first.

## Decision queue

Changes are admitted only with an A/B result:

1. `VICTORY_UPLOAD_AHEAD=1` on the stable profile, to reduce texture waiting
   during region changes.
2. Six-core worker tuning: 4 translation threads, 4 joined parts and 2 mapping
   workers, to reduce oversubscription against the title's threads.
3. `VICTORY_CARD_BUFFERS_MIN_KB=64` only if freed VRAM remains sufficient;
   current dedicated VRAM headroom is too small to assume this is free.
4. Relay stages and `TEXTURE_NO_WAIT` only after their documented RDNA 2 device
   loss behavior is re-tested together with `BURY_LAG=0`.
5. Release build comparison after the diagnostics build has established the
   bottleneck.

AFMF, FSR frame generation and synthetic frame duplication are not enabled.
The tree has no integrated FSR spatial/temporal upscaler to validate, so no FSR
quality or scaling result is claimed.

## Open gaps

- PresentMon capture must be summarized after the session process exits and
  releases its CSV.
- A repeatable save/scene must be used for candidate runs.
- RGP/RMV/RGA/RRA/RGD counters are unavailable on this machine.
- Ten-minute stable validation at the winning profile remains required.
## PortWatch snapshot and upstream merge (2026-11-26T10:23:53Z)

PortWatch's current public board:

| Score | Project | Reported GPU / FPS | Usability here |
|---|---|---|---|
| 91.5% | `codec-d/cool_fox` (CGBJ) | NVIDIA, 25 fps | Repository currently returns 404; code cannot be applied |
| 83.1% | `avatarmanz/VIctory-7900XTX` | AMD, 16 fps | Base upstream |
| 79.0% | `Belobug/VIctory-Belobug-AMD` | AMD, 8 fps | Already credited and partly merged upstream |
| 78.0% | `DexNom/VIctory` | AMD, 3 fps | Already credited and partly merged upstream |
| 68.8% | `fablinoo/kelvaroq` | NVIDIA, 10 fps | Public, but lower score and NVIDIA-specific; no direct change admitted yet |

The Avatar upstream had advanced 152 commits from our fork point. The branch
merged `0dec5dc` without conflicts. Relevant additions include:

- title-owned output size and render scale (`VICTORY_OUTPUT`,
  `VICTORY_RENDER_SCALE`, `VICTORY_UPSCALER`);
- frame pacing unlock (`VICTORY_FRAME_INTERVAL_MS`);
- renderer ports for constants, descriptors and CBV;
- AMD-safe CoolFox two-plane compose, barrier and table-plan work;
- pipeline-book write retry and orderly-exit flushing;
- DirectStorage staging floor (`VICTORY_DSTORAGE_STAGING_MB`).

## A/B decisions after the merge

Baseline and candidates used the same save, Series X profile, RX 6700 XT,
driver `32.0.21045.5002`, and AFMF/frame generation off.

| Candidate | Observed | Decision |
|---|---|---|
| Sync relay 0, 4K output | 3–4 fps, ~240–315 ms | compatibility baseline |
| Port descriptors + constants on relay 0 | 3–4 fps, no measured gain; heavier load transient | rejected |
| Relay 1 + 1080p + 0.75 scale | 9–10 fps, ~104–115 ms | keep relay and resolution |
| Port constants + CBV on relay 1 | 0.2–4.6 fps, 1–6 s preparation in the world | rejected |
| Relay 1 + 1080p + 0.5 scale | 10.6–10.9 fps, ~92–95 ms, GPU ~27 ms | selected |
| Relay 2 + 0.5 scale | not validated: session stopped at player selection | not default |

The winning profile roughly doubled or tripled frame rate while keeping the GPU
below saturation. The remaining representative 0.5-scale frame costs about
62 ms preparing (28 ms copies), 27 ms GPU and 23 ms copy-back.

`VICTORY_DSTORAGE_STAGING_MB=256` is exposed by `-FastLoad`. Its load-time gain is
still being measured and is not claimed yet.

## Current default

`scripts/play-rx6700xt.ps1` now defaults to `redline`:

- relay 1, retirement lag 0, card steps 0;
- output 1920x1080, internal scale 0.5, title upscaler;
- six translator/join workers and four mapping workers;
- no frame generation and no ray tracing;
- `-Stable` for the previous relay-0 path, `-Safe` for the minimal path;
- `-FastLoad` for the DirectStorage staging experiment.

The current Release session is the first validation of this exact script.
## Final A/B results and selected profile

Further runs after the first Redline result:

| Candidate | Steady result | Decision |
|---|---|---|
| Redline, 6/6/4 workers | 10–11 fps, 92–104 ms | baseline |
| Redline + 4/4/2 workers | 11–12 fps, ~84–91 ms | selected |
| LowCopy alone | 9–10 fps, ~95–105 ms; lower private memory | optional memory profile |
| LowCopy + 4/4/2 workers | 10–11 fps, 91–103 ms | not selected |
| Relay 2 | 1–8 fps, much longer frames | rejected |
| Upload ahead | 9–10 fps, no steady gain | rejected |
| Port constants + CBV | 0.2–4.6 fps and multi-second copies | rejected |

The selected profile uses:

- output 1920x1080; title upscaler; internal render scale 0.5;
- relay 1; `VICTORY_BURY_LAG=0`; `VICTORY_CARD_STEPS=0`;
- texture no-wait and upload-ahead off;
- four list-translation workers, four joined parts, two mapping workers;
- ray tracing and all frame generation off.

The current recommended launch is:

```powershell
scripts\play-rx6700xt.ps1 -Exe <game.exe> -Build release -FastLoad
```

`-FastLoad` raises DirectStorage staging to 256 MiB. It is exposed as an
isolated switch; a load-time gain has not yet been isolated from the time spent
at the player-selection prompt, so it is not claimed as measured.

Expected result on this machine in the tested dense city scene is 11–12 fps and
roughly 84–96 ms per frame. This is about three times the original 3–4 fps
baseline, but remains below the 20 fps target. The measured remaining wall is
CPU-side preparation and title-memory copies, not frame generation or raw GPU
raster throughput.

The final Release session was left running for physical-controller testing.