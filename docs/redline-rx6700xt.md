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
## Resolution floor correction

The active test session used 1920x1080 output with a 0.5 render scale, which is
960x540 internally. The requested range is 720p to 1080p, so the next session
changes the internal scale to `0.6666667`: 1280x720 internal, 1920x1080 output.
The title's own upscaler remains in use. Historical measurements at 0.5 stay in
the table above; they are not relabelled as 720p.
## Next automated test

The current Release session did not close by the second monitoring window and was
left in its menu. A watcher is armed to launch the next candidate only after the
current process exits:

- 1920x1080 output and 1280x720 internal rendering;
- relay 1, 4/4/2 workers, `-FastLoad`;
- `-Bar`: `VICTORY_WINDOWS_BAR_MB=3072`, `VICTORY_SEND_BAR=1`.

The purpose is to test whether moving large windows and send buffers through BAR
can remove enough CPU-side copy time to exceed 12 fps while respecting the 720p
floor.
## Latest PortWatch snapshot and upstream delta (2026-11-26T13:35:57Z)

The live `https://portwatch-vi.xyz/data/tracker.json` snapshot reports:

| Score | Project | Reported GPU / FPS | Action here |
|---|---:|---|---|
| 91.5% | `codec-d/cool_fox` (CGBJ) | NVIDIA / 25 fps | Public source now returns 404; cannot apply |
| 87.8% | NotNozy | AMD / 16 fps | Private build; no code to inspect |
| 84.8% | darkworldhm | NVIDIA / 15 fps | No public code available from the tracker |
| 84.0% | Doomsday | AMD + NVIDIA / 4 fps | Lower measured gain than the current base |
| 83.1% | `avatarmanz/VIctory-7900XTX` | AMD / 16 fps | Base for this fork |
| 79.0% | `Belobug/VIctory-Belobug-AMD` | AMD / 8 fps | Many fixes are already credited upstream |
| 78.0% | `DexNom/VIctory` | AMD / 3 fps | Its Radeon fixes are partly merged upstream |
| 68.8% | `fablinoo/kelvaroq` | NVIDIA / 10 fps | Different CPU-submission design; not admitted without an RX 6700 XT A/B |
| 68.2% | `fxceless/victory-fork` | NVIDIA / 3 fps | Useful instrumentation and worker experiments; not a direct merge |

AvatarManz advanced from `0dec5dc` to `c9c932c`. The new work merges renderer
ports 6 and 7:

- `VICTORY_PORT_GUARD=1` shares the write-guard lock and moves refresh
  planning beside the submitting thread. Upstream measured title-thread waits
  falling from 29 ms to about 2 ms per frame and a 2 ms frame-time gain.
- `VICTORY_PORT_JOURNAL=1` asks for the heaps' records at submit and splits
  journal notes into 64 locked parts. Upstream measured the submit-thread wait
  falling from roughly 6 ms to 0.3 ms and a 1-3 ms frame-time gain.
- Upstream's combined renderer-port result on its 7900 XTX test scene was
  45.8 to 44.9 ms per frame (about 21.8 to 22.3 fps).

This branch merged that upstream state as commit `63ff417`. The new switches
remain off by default. `scripts/play-rx6700xt.ps1` now exposes them as
`-PortGuard`, `-PortJournal`, and the combined `-PortTune` candidate. They have
not yet been claimed as improvements on the RX 6700 XT.

## Live 720p + BAR validation

The current Release session uses 1920x1080 output, a 1280x720 internal render
scale, relay 1, DirectStorage staging, and BAR. In the first scene after the
boat, the title's own counter showed:

- a worst sampled frame at 2 fps / 456.6 ms with 7,937 draws;
- repeated 3-5 fps samples at 180-265 ms;
- recovery to 7-9 fps / 108-144 ms in the same area;
- 23.15-23.65 GiB private memory and no increase indicating exhaustion;
- no `ERROR`, TDR, DXGI device removal, crash or watchdog line.

Windows GPU Engine counters showed the compute engine at 99-100%, the 3D engine
at roughly 19-36%, and copy at about 1%. This makes the low frame rate a real
scene cost on this PC. The upstream guard/journal fixes target CPU-side waits,
so they may not recover all of the compute-bound frames; they still form the
next low-risk A/B because both are isolated switches.

## Latest public notes applied locally (2026-11-26T16:18:31Z)

PortWatch refreshed its JSON data at 16:18 UTC. The public scoreboard moved to:

| Score | Project | Reported GPU / FPS | Local decision |
|---|---:|---|---|
| 89.6% | CGBJ | unknown / 25 fps | Repository still unavailable; no code admitted |
| 87.1% | NotNozy | AMD / 16 fps | Private build; no code to inspect |
| 84.8% | darkworldhm | NVIDIA / 15 fps | No public source on the tracker |
| 82.1% | Doomsday | AMD + NVIDIA / 4 fps | Lower measured FPS than this profile |
| 81.8% | `avatarmanz/VIctory-7900XTX` | AMD / 16 fps | Code remains at `c9c932c`; only the README advanced to `2de9980` |
| 77.4% | `DexNom/VIctory` | AMD / 3 fps | No new performance commit in this refresh |
| 77.2% | `Belobug/VIctory-Belobug-AMD` | AMD / 8 fps | No new AMD performance commit in this refresh |
| 68.8% | `stellarr-studio/kelvaroq` | NVIDIA / 10 fps | Repository moved from `fablinoo`; its process-copy patch was admitted and tested here |

Kelvaroq's latest public notes report that its process-copy patch cut heavy-frame
time by 7-12% above 5,000 draws and removed one-second spikes. Its wide GPU hash
and 12 GB class card-buffer defaults were already present in this AvatarManz
tree, so only the missing copy path was ported.

### In-process title-memory copy

The branch `rx6700xt-kelvaroq-opt` now includes `plaincopy.rs` from Kelvaroq's
patch 0044. Reads into host memory first use the processor copy path; a title
page fault falls back to the same range through `ReadProcessMemory`. Reads under
256 bytes and recently faulted 64 KiB blocks stay on the kernel path. Title
destinations continue to use the kernel path.

`VICTORY_COPY_PLAIN=0` restores the previous behavior. The launcher exposes this
comparison as `-KernelCopy`; the fast process-copy path is the default.

Validation on this checkout:

- `cargo test -p victory-gpu plaincopy::x64::tests --lib`: 5 passed;
- `cargo check -p victory --features diagnostics`: passed;
- tests cover missing interior pages, guarded aliases, one-shot Windows guards,
  small-read fallback and cooldown after a fault.

This changes title-memory reads, not the game data, save, resolution or control
mapping. The next game run must still establish the RX 6700 XT frame-time delta;
the 7-12% figure remains Kelvaroq's measurement on its own NVIDIA test machine
until reproduced here.

## First process-copy game run

Launch on 2026-11-26 at 13:55 local time:

- Release build with the Kelvaroq process-copy path;
- `-FastLoad -Bar -PortTune`;
- output 1920x1080, internal render scale 0.6666667 (1280x720);
- Relay 1, 4/4/2 workers, ray tracing and frame generation off.

After the save loaded, the first heavy view began at 9 fps / about 109 ms
with 12,110 draws. The next ten minutes stayed between 6 and 10 fps at
5,966-13,172 draws, with most settled samples at 7-10 fps and 99-158 ms.
No sample produced the 600-1,000 ms stalls seen repeatedly in the previous
session. Private memory reached 22.70 GiB and settled near 22.5 GiB, below the
25.8 GiB peak of the old path.

The CPU profile changed from one thread near 93% of a core plus a 99-100%
compute engine to roughly 440% process CPU spread over eight helper/title
threads, while compute remained near 100%. The remaining limit in these sampled
views is therefore GPU compute, not a single copy thread. No runtime, DXGI, TDR
or Windows driver error appeared.

This is a before/after observation on the same save area, not an in-run switch:
the launcher now records `VICTORY_COPY_PLAIN=1` explicitly. `-KernelCopy` sets it
to `0` for the next controlled A/B. `-SeriesS` is also available for the
upstream-measured, approximately 5 ms lighter console profile; it has not been
claimed as a local gain until it is run here.

## Series S, short hash and native-720 A/B (2026-11-26)

All runs kept the process-copy path, Relay 1, BAR, renderer ports 6/7,
4/4/2 workers, 720p internal rendering and no frame generation.

| Profile | Typical heavy view | Memory | Result |
|---|---|---|---|
| Series X + 720p -> 1080p | 6-10 fps, 99-180 ms | ~22.5 GiB private | baseline after process copies |
| Series S + 720p -> 1080p | 9-11 fps, 94-115 ms | ~20.6 GiB private | selected |
| Light Series S view | 20-25 fps | ~20.5 GiB private | consistent with a real draw-count drop |
| Series S + short card hash | 6-11 fps, 93-172 ms | ~20.0 GiB private | no consistent gain; remains opt-in |
| Native 1280x720, upscaler omitted | failed before gameplay | n/a | rejected |

The selected Series S run loaded the same save, held 9-11 fps at 7.2-10.1k
draws, and exited after about six minutes without an Application Error, WER,
AMD display event or new VIctory crash record. The GPU compute engine remained
at about 98-99%, so the gain comes from less work in the Series S render path,
not from lowering resolution.

`VICTORY_CARD_HASH_LEN=1` did not produce a repeatable gain in the sampled
views. It is exposed as `-ShortHash` for further tests but is not selected.

The native-720 test was invalid on this build. The logs reported
`FSR_API_DEBUG_ERROR: Shipping FSR4 configuration mismatch: maxUpscaleSize
must be 1920x1080; received 1280x720`, followed by an unhandled divide-by-zero
at `0xc0000094`. The broken `-Native720` launcher path was removed. The title's
fixed FSR4 tables require the 1920x1080 output target, so internal 720p must
remain the 720-to-1080 upscale path.

The Redline launcher now defaults to Series S. `-SeriesX` selects the previous
profile for A/B tests; `-SeriesS` remains accepted for compatibility.
