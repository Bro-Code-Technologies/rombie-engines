# Rombie's netplay engine

The engine Rombie runs when players in an Invite to Play session each run the game on their own PC and only button
presses travel between them. It is a small libretro frontend of Rombie's own, `netplay-main.c`, statically linked with
one libretro core per build and compiled to WebAssembly. It runs one frame at a time with the inputs it is given, and
keeps a ring of save states so it can go back to a recent frame and run it again with corrected inputs (rollback).
Solo play in Rombie does not use it; that runs RetroArch through Nostalgist.

Rombie cannot drive netplay through RetroArch's web build: that build exports only RetroArch's own commands, not the
core's `retro_run`, `retro_serialize` or `retro_unserialize`, its frame advance is a queued command run by its own
main loop, and input reaches it through keyboard and gamepad events on its own schedule.

## How Rombie talks to it

The engine runs in a dedicated Web Worker, and Rombie reaches it only through `postMessage`. The build appends
`netplay-worker.js` to the Emscripten output (`--post-js`), so the one built `.js` file is the Worker script: it owns
the module and is the only code that calls the engine's functions. Rombie's own code never runs inside that Worker.
Single-threaded, so no `SharedArrayBuffer` and no cross-origin isolation.

| File | What it is |
| --- | --- |
| `netplay-main.c` | The libretro frontend: environment, video, audio and input callbacks, the state ring, hashes |
| `netplay-worker.js` | The Worker's message handling, built into the engine's `.js` |
| `build.sh`, `Dockerfile` | The build (see Building) |
| `test.html` | A check of the engine on its own (see Testing); not shipped |
| `fceumm/` | The NES core, a submodule pinned to its commit |
| `supafaust/` | The SNES core, a submodule pinned to its commit |
| `patches/mednafen_supafaust.patch` | Supafaust's changes for a build with no threads, the same as `snes/patches/` |

### Messages

Every request may carry an `id`, which its reply repeats. A request that fails gets
`{ type: 'error', id, request, message }`. Requests sent before the module has finished compiling wait and run in
order; the engine posts `{ type: 'ready' }` when it is up.

| Request | Reply |
| --- | --- |
| `load { rom, name, options?, devices?, sram?, system? }`: the game's bytes and file name, core options as `{ key: value }`, a device per port, save RAM, and files for the core's system folder as `[{ name, data }]` | `loaded { library, fps, sampleRate, baseWidth, baseHeight, aspectRatio, stateSize, sramSize, frame }` |
| `run { from, inputs, audioFrom?, video?, hashes? }`: run frames from `from` with the given inputs. When `from` is behind the engine it first rolls back to it from the ring. Sound is kept for frames from `audioFrom` on (default `from`); only the last frame is drawn, unless `video: false` | `ran { frame, video, audio, hashes, memoryHashes, videoHashes, engineMs }`: the next frame to run, the picture `{ width, height, pixels }` (RGBA), the sound (interleaved stereo `Int16Array` buffer), and with `hashes: true` three per-frame hash arrays (see below) |
| `checksum { frame }` | `checksum { frame, hash }`: the hash of the state before `frame`, or `null` when the ring no longer holds it |
| `save` | `state { frame, data }`: the full state, which is the state before `frame` |
| `loadState { data, frame }` | `stateLoaded { frame }`: the state becomes the state before `frame`, and the ring starts over |
| `sramGet` | `sram { data }` (`null` when the game has none) |
| `sramSet { data }` | `sramSet { written }` |
| `options { options }` | `options` |
| `device { port, device }` | `device` |
| `reset` | `reset { frame }` |
| `bench { iterations? }` | `bench { stateSize, serializeMs, unserializeMs, frameMs }`, averages measured inside the engine |
| `unload` | `unloaded` |

Buffers in replies are transferred, not copied.

**Inputs.** `inputs` is an `Int16Array` buffer of 20 values per frame: for each of four ports, the buttons as
libretro's joypad bitmask (bit `RETRO_DEVICE_ID_JOYPAD_*`: B 0, Y 1, Select 2, Start 3, Up 4, Down 5, Left 6,
Right 7, A 8, X 9, L 10, R 11, L2 12, R2 13, L3 14, R3 15), then the left stick's x and y and the right stick's x
and y.

**Frames.** Frames are numbered from 0 at load. Before running frame `f`, the engine saves the state into the ring;
that is "the state before `f`". The ring holds 16 states, so the engine can roll back up to 15 frames.

**Hashes.** With `hashes: true`, each frame run reports three hashes: `hashes`, of the state before the frame (the
whole saved state); `memoryHashes`, of the game's own memory at the same moment (system RAM, video RAM and save RAM,
as far as the core exposes them); and `videoHashes`, of the picture the frame drew. Compare game memory and pictures
to tell whether two engines are playing the same game. A core's saved state can also hold parts that loading it does
not restore exactly, so after a rollback the whole state can differ from a straight run's while the game does not.
fceumm at this commit does this in two places, and neither affects the game:

- its sound: `sweepReload` and `DMCDMABuf` are not saved, so the sound filter (`FAC1`, `FAC2`), the DAC level
  (`RWDA`) and the start of the wave buffer (`WAVE`) take a little while to come back together;
- MMC1 (`boards/mmc1.c`): loading a state sets `lreset` (`LRST`) to 0. It only guards against two writes within two
  CPU cycles, which never span a frame.

Supafaust is the other way round: it exposes no memory to the frontend but its save RAM, so `memoryHashes` says
little, while its whole state comes back exactly after a rollback (no mismatches in the five games of the checks
below). Rombie compares the whole state for SNES.

## The cores

| Core | Submodule, commit | License | Built |
| --- | --- | --- | --- |
| fceumm (NES) | `fceumm`: [libretro/libretro-fceumm](https://github.com/libretro/libretro-fceumm) `5cd4a43e16a7f3cd35628d481c347a0a98cfdfa2` | GPL-2.0-or-later | `fceumm.js`, `.wasm` |
| Beetle Supafaust (SNES) | `supafaust`: [libretro/supafaust](https://github.com/libretro/supafaust) `642d1d1b6684aa7e306a02a89885f3f5456a5157` | GPL-2.0-or-later | `supafaust.js`, `.wasm` |

This is the commit libretro's buildbot built for RetroArch 1.22.2 (its core reports "(SVN) 5cd4a43"), which is the
build Rombie's solo NES runs (Nostalgist's cores come from `arianrhodsandlot/retroarch-emscripten-build@v1.22.2`,
the buildbot's files unchanged). A solo game's save state therefore loads here: unwrapped from RetroArch's file
(RZIP-compressed, with the core's state in the `MEM` block of a `RASTATE` container), it is exactly the core's state,
13,805 bytes for Super Mario Bros. 3.

The core is built the way libretro builds it for Emscripten (`platform=emscripten`). A statically linked core leaves
libretro-common's file, memory-stream and string helpers to the frontend, so `build.sh` compiles the core's own copy of
them into the engine.

Supafaust is the commit Rombie's solo SNES runs, built in `snes/` with the same patch, so a solo SNES game's state
loads here the same way. It is built as `snes/` builds it (`platform=emscripten`, WebAssembly exceptions, which
Mednafen uses in ordinary control flow) and linked as C++. Its own `libretro.h` predates calls the frontend handles,
so the frontend is compiled against fceumm's copy of the header; the libretro interface itself is unchanged. Its
multitap is a core option (`supafaust_multitap`), which Rombie sets at `load`, as solo play does.

## Building

From the repo root, with the submodules checked out (`git submodule update --init netplay/fceumm netplay/supafaust`):

```sh
docker build -t rombie-netplay netplay
docker run --rm -v "${PWD}:/repo" rombie-netplay sh /repo/netplay/build.sh
```

The image is Emscripten 3.1.46, pinned by digest, the same as `snes/`. The output lands in `netplay/out/`, one
`.js` and `.wasm` per core, with their `SHA256SUMS`. Builds are byte for byte the same each time; this source builds:

```
a880bff0e28a3ffe31b20af67e62b49bae197ed1fbf7aef77df6a2113082d9cb  fceumm.js
e9ff8cf9b393c8c6842f5c1542da0887844e41c1e3ee72a3df038b49af2a2131  fceumm.wasm
488644f2db259372cd89ce26fa5452721f71c4a2f9913c6b237375b5ea98134d  supafaust.js
56d5d486a5f6e7aaceb2b6276f0c4b5054e58cbba2fa92a2cd65633f3053ec09  supafaust.wasm
```

## Testing

`test.html` checks the engine on its own. Serve this folder over HTTP after building (a Worker will not start from
`file://`), for example `python -m http.server 8642` here, open `http://localhost:8642/test.html` (the NES engine;
`test.html?engine=out/supafaust.js` for SNES), pick a ROM and run:

- **Determinism**: engine A runs scripted two-player input straight; engine B runs the same input the way a guest's
  rollback session does (player 1's input arrives up to 7 frames late, B repeats the last one it knows, then rolls back
  and runs again when the real one comes). Game memory and picture must match on every frame; the whole state is
  reported too, with the parts that differ named. "real time" runs it at 60 fps to watch, and "control" gives B inputs
  A never sees, which must fail.
- **Timings**: save, load and one frame, measured inside the engine.
- **Stress**: every frame, roll back 8 frames and run them again plus one new frame, at 60 fps, counting the page's
  message round trips.
- **Solo state**: load a core state taken from a RetroArch save state and play on.

Supafaust, 36,000 frames each (10 minutes of play) with 2,621 rollbacks, on the PC the engine was built on (2026-10-10):

| Game | Frame | State | Stress (8 back, every frame) | Mismatches (picture, whole state) |
| --- | --- | --- | --- | --- |
| Super Mario World | 1.4 ms | 268,568 B | 60.0 fps, 68% of the frame | 0, 0 |
| Star Fox (SuperFX) | 1.6 ms | 299,966 B | 60.0 fps, 73% | 0, 0 |
| Donkey Kong Country | 1.5 ms | 268,568 B | 59.9 fps, 76% | 0, 0 |
| Yoshi's Island (SuperFX 2) | 1.8 ms | 299,966 B | 58.6 fps, 80% | 0, 0 |
| Super Mario RPG (SA-1) | 3.3 ms | 301,609 B | 34.6 fps, 173% | 0, 0 |

An SA-1 game cannot run eight frames again every frame on that PC. Netplay rolls back only when another player's input
turns out different, and only as far as it arrived late, so this is the worst case rather than the usual one.

## Licenses

fceumm and Supafaust are GPL-2.0-or-later; their own copies of the license (`Copying`, `COPYING`) are in the
submodules, and `LICENSES/GPL-2.0.txt` holds the same license's text. The files written for this folder
(`netplay-main.c`, `netplay-worker.js`, `build.sh`, `Dockerfile`, `test.html`, this README) are GPL-2.0-or-later too,
since the engines link GPL cores, and so is the Supafaust patch. The libretro-common files compiled in from fceumm's
source are MIT, as their headers say.
