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
| `pcsx_rearmed/` | The PS1 core, a submodule pinned to its commit |
| `gearsystem/` | The Master System and Game Gear core, a submodule pinned to its commit |
| `emu2413/` | Okazaki's YM2413 emulator, a submodule pinned to its commit, which Gearsystem is built with in place of the one file it has from Genesis Plus GX |
| `overlay/` | The two files that stand in for Gearsystem's `src/audio/emu2413/emu2413.c` and `.h` (see The cores) |
| `patches/mednafen_supafaust.patch` | Supafaust's changes for a build with no threads, the same as `snes/patches/` |
| `patches/pcsx_rearmed.patch` | pcsx_rearmed's changes so a loaded state runs on exactly as the saved one would (see The cores) |

### Messages

Every request may carry an `id`, which its reply repeats. A request that fails gets
`{ type: 'error', id, request, message }`. Requests sent before the module has finished compiling wait and run in
order; the engine posts `{ type: 'ready' }` when it is up.

| Request | Reply |
| --- | --- |
| `load { rom, name, files?, options?, devices?, sram?, system? }`: the game's bytes and file name, or for a disc its files as `[{ name, data }]` with `data` a `Blob`, mounted read-only and read as the core asks (never copied whole into memory; `name` is the one to load, a `.cue` names the others); core options as `{ key: value }`, a device per port, save RAM, and files for the core's system folder (a BIOS) as `[{ name, data }]`. The core starts here, once its system folder and options are in place, since some look for their BIOS as they start | `loaded { library, fps, sampleRate, baseWidth, baseHeight, aspectRatio, stateSize, sramSize, frame }` |
| `run { from, inputs, audioFrom?, video?, hashes? }`: run frames from `from` with the given inputs. When `from` is behind the engine it first rolls back to it from the ring. Sound is kept for frames from `audioFrom` on (default `from`); only the last frame is drawn, unless `video: false` | `ran { frame, video, audio, hashes, memoryHashes, videoHashes, engineMs }`: the next frame to run, the picture `{ width, height, pixels }` (RGBA), the sound (interleaved stereo `Int16Array` buffer), and with `hashes: true` three per-frame hash arrays (see below) |
| `checksum { frame }` | `checksum { frame, hash }`: the hash of the state before `frame`, or `null` when the ring no longer holds it |
| `save` | `state { frame, data }`: the full state, which is the state before `frame` |
| `loadState { data, frame }` | `stateLoaded { frame }`: the state becomes the state before `frame`, and the ring starts over |
| `sramGet { memory? }` | `sram { data }` (`null` when the game has none) |
| `sramSet { data, memory? }` | `sramSet { written }` |
| `options { options }` | `options` |
| `device { port, device }` | `device` |
| `reset` | `reset { frame }` |
| `bench { iterations? }` | `bench { stateSize, serializeMs, unserializeMs, frameMs }`, averages measured inside the engine |
| `unload` | `unloaded` |

Buffers in replies are transferred, not copied.

**Save RAM.** `memory` is a libretro memory id, `RETRO_MEMORY_SAVE_RAM` (0) when absent. Gearsystem with its link on
runs two consoles, whose save RAM are `0x100` and `0x200` (0 is the first console's too); every other core has the one.

**Inputs.** `inputs` is an `Int16Array` buffer of 20 values per frame: for each of four ports, the buttons as
libretro's joypad bitmask (bit `RETRO_DEVICE_ID_JOYPAD_*`: B 0, Y 1, Select 2, Start 3, Up 4, Down 5, Left 6,
Right 7, A 8, X 9, L 10, R 11, L2 12, R2 13, L3 14, R3 15), then the left stick's x and y and the right stick's x
and y.

**Frames.** Frames are numbered from 0 at load. Before running frame `f`, the engine saves the state into the ring;
that is "the state before `f`". The ring holds 16 states, so the engine can roll back up to 15 frames.

**Hashes.** With `hashes: true`, each frame run reports three hashes: `hashes`, of the state before the frame (the
whole saved state); `memoryHashes`, of the game's own memory at the same moment (system RAM, video RAM and save RAM,
as far as the core exposes them); and `videoHashes`, of the picture the frame drew (0 when it drew none, as every
other frame of a 30 fps game). Compare game memory and pictures to tell whether two engines are playing the same
game. A core's saved state can also hold parts that loading it does not restore exactly, so after a rollback the whole
state can differ from a straight run's while the game does not.
fceumm at this commit does this in two places, and neither affects the game:

- its sound: `sweepReload` and `DMCDMABuf` are not saved, so the sound filter (`FAC1`, `FAC2`), the DAC level
  (`RWDA`) and the start of the wave buffer (`WAVE`) take a little while to come back together;
- MMC1 (`boards/mmc1.c`): loading a state sets `lreset` (`LRST`) to 0. It only guards against two writes within two
  CPU cycles, which never span a frame.

Supafaust is the other way round: it exposes no memory to the frontend but its save RAM, so `memoryHashes` says
little, while its whole state comes back exactly after a rollback (no mismatches in the five games of the checks
below). Rombie compares the whole state for SNES. Gearsystem's does too, with the link on: both consoles are in the
state, which comes back exactly after a rollback (see Testing), while `memoryHashes` covers the first console only.

## The cores

| Core | Submodule, commit | License | Built |
| --- | --- | --- | --- |
| fceumm (NES) | `fceumm`: [libretro/libretro-fceumm](https://github.com/libretro/libretro-fceumm) `5cd4a43e16a7f3cd35628d481c347a0a98cfdfa2` | GPL-2.0-or-later | `fceumm.js`, `.wasm` |
| Beetle Supafaust (SNES) | `supafaust`: [libretro/supafaust](https://github.com/libretro/supafaust) `642d1d1b6684aa7e306a02a89885f3f5456a5157` | GPL-2.0-or-later | `supafaust.js`, `.wasm` |
| PCSX ReARMed (PS1) | `pcsx_rearmed`: [libretro/pcsx_rearmed](https://github.com/libretro/pcsx_rearmed) `228c14e10e9a8fae0ead8adf30daad2cdd8655b9` | GPL-2.0-or-later | `pcsx_rearmed.js`, `.wasm` |
| Gearsystem (Master System and Game Gear) | `gearsystem`: [drhelius/Gearsystem](https://github.com/drhelius/Gearsystem) `517ddaaafbab1af7a312c2b6b6f6043275f58500` (3.9.22) · `emu2413`: [digital-sound-antiques/emu2413](https://github.com/digital-sound-antiques/emu2413) `2e4f6f9752f43cc33572c6636ca31a647600732c` (1.6.2) | GPL-3.0-or-later (Gearsystem and the files in `overlay/`) with MIT (emu2413) | `gearsystem.js`, `.wasm` |

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

pcsx_rearmed is the commit libretro's buildbot built for RetroArch 1.22.2 (its core reports "r25 228c14e"), which
Rombie's solo PS1 runs, so a solo PS1 game's state loads here. `platform=emscripten` builds it with no threads, no
dynamic recompiler (the interpreter) and no asynchronous CD reads. It reads CHD and PBP images with zlib, which
Emscripten builds from its zlib 1.2.13 port (downloaded during the build and checked against the hash Emscripten
pins). Its frontend submodule `frontend/libpicofe` is for its standalone build and is not needed. Its state does not
come back exactly after a load as it stands, so a rolled-back engine drifted from one that ran straight within a few
frames. `patches/pcsx_rearmed.patch` makes a load restore what the game goes on to depend on, found by comparing
each part of the emulator after a load with a straight run at the same frame. It changes neither the state's size nor
its format, and a state from an unpatched build (solo play) loads as before:

- the interpreter's fractional cycle count and its delayed-load selector (`psxRegs.subCycle`, `dloadSel`), which are
  not in the state and which a load sets to 0, are kept in the state's spare block (`misc_save_data`) and set back
  after the load;
- loading the root counters rewrote each running counter's start cycle from its count, dropping the part of a tick
  already counted; the patch keeps it;
- loading the GPU replays its control writes, which acknowledged an interrupt and left the "picture changed" and
  "blanked" flags set, so the next frame was shown where a straight run repeated the last one; the patch stores the
  two flags in a slot of the GPU block nothing else uses and, for a state that has them, restores the registers, the
  status and the flags after the replay;
- loading the CD-ROM controller recomputed the size of the sector waiting in its FIFO from the current mode, which a
  game can change after the sector arrived; the patch keeps the saved size;
- the memory cards' "new card" flags, which start set and clear when the game first reads a card, are not in the
  state, so an engine that had just started (a guest joining) told the game its card was new where the host's had
  long been read, and the game went another way at its next card check; the patch keeps the flags in the spare block,
  marked, so a state without them leaves them as they are;
- an engine that had just loaded its game had a picture pending from opening its GPU, so after loading a state its
  first frame showed one where the saved engine's did not; the patch clears it on a load, as it is between any two
  frames.

The frontend also stops a core reading again, at its first frame, the options it was loaded with (pcsx_rearmed reopens
its GPU when it does), so a new engine starts from a state as one already running does; Rombie sets the options again
on every engine as netplay starts or starts over, so all of them take them in at that same frame.

What a load still resets is sound only: the sound chip's dirty flags, its clearing of the CD capture buffers and where
its XA audio buffer starts. The whole saved state also differs between engines in a save counter and in bytes of the
GPU block that are never read, so Rombie compares game memory and pictures for PS1, as for NES. A disc with several
tracks is loaded through its `.cue`; a disc set with an `.m3u` (several discs) is not supported.

Gearsystem is the commit Rombie's solo Master System and Game Gear runs (`gearsystem/` in this repo), with the same
replacement for its YM2413 chip (see Licenses), so a solo game's state loads here. It is built as libretro builds it
for Emscripten (`platform=emscripten`, C++ without exceptions) and brings no libretro-common helpers, so the frontend
is compiled against its own `libretro.h`. What this build is for is the Game Gear link. With
`gearsystem_link_enable` on and a native Game Gear game, the one core runs two consoles of the same game: port 0 is the
first console's pad and port 1 the second's, `gearsystem_link_screen` and `gearsystem_link_audio` choose which of
them is drawn and heard (`Screen 1`, `Screen 2`, or both), and the two consoles' save RAM are memory ids `0x100` and
`0x200`. The link cable between the consoles is inside the core, stepped in lockstep within one process: it cannot
cross a network (the consoles must agree within 32 CPU cycles, and every read of a link port waits for the other
console), so a session runs both consoles on each PC and exchanges only the pads, the host's state at the start and
the checksums, as it does for any other core. Each PC sets the screen and sound options to the console it plays; they
change what is shown and heard and nothing in the state (see Testing). The state is 862,028 bytes with the link on
(199,406 without). A game that is not in native Game Gear mode (a Master System game, or a Game Gear game that runs
in Master System mode) runs on one console as it does solo.

## Building

From the repo root, with the submodules checked out (`git submodule update --init netplay/fceumm netplay/supafaust
netplay/pcsx_rearmed netplay/gearsystem netplay/emu2413`; pcsx_rearmed's own submodules are not needed):

```sh
docker build -t rombie-netplay netplay
docker run --rm -v "${PWD}:/repo" rombie-netplay sh /repo/netplay/build.sh
```

The image is Emscripten 3.1.46, pinned by digest, the same as `snes/`. The output lands in `netplay/out/`, one
`.js` and `.wasm` per core, with their `SHA256SUMS`. Builds are byte for byte the same each time; this source builds:

```
f63f8aa657a76ca533d5adb222082f1366eaa36da5c0c9a58c7f313e599e8d0f  fceumm.js
3a2aba3c32a10824798790942b08a7322f7bf0cdff2f1daf82a2e45829d177a0  fceumm.wasm
0f7386a99e588bbc4f639d13964581efddc16e2a10862732c9ea293674ad2a0f  supafaust.js
df836dc3a85af382f448d9c3be817941ec02f141998f6ee07643ab838619e7d6  supafaust.wasm
f4b9cc2fccdeac7eb73650f40952eca6a9af43c4c906696269096a2e7944fe3a  pcsx_rearmed.js
8830e7137c1826e7704af8cda21094480bde1c67aae92266bcd149c74a5eba0a  pcsx_rearmed.wasm
3446d56d2d636eedaa23824bf070845e8974845e2bf57c285a17f9a9c5d4695e  gearsystem.js
bfe4b1594b335013d180c7e5860227f1ed2a592b8109df1669e8f4dff6311ff5  gearsystem.wasm
```

All eight files changed from `rombie-netplay-engine-2026.0.1`: the frontend's save RAM calls take a memory id, which
every core's build links, and the Worker script is built into each. The NES, SNES and PS1 engines were run again on one game each (Super Mario
Bros. 3 for 12,000 frames, Super Mario Kart for 12,000, Spyro the Dragon for 3,000), and give the results documented
here: game memory and picture match, apart from the one boot frame of Spyro's (frame 253), and the whole saved state
differs where it is said to (NES's sound filter, PS1's save counter, SNES's DSP-1 block).

## Testing

`test.html` checks the engine on its own. Serve this folder over HTTP after building (a Worker will not start from
`file://`), for example `python -m http.server 8642` here, open `http://localhost:8642/test.html` (the NES engine;
`test.html?engine=out/supafaust.js` for SNES; `?engine=out/pcsx_rearmed.js` for PS1, picking all of a disc's files and a BIOS; `?engine=out/gearsystem.js` for a Game Gear game's link, with the link on and engine B on the second console as a session's guest has it, and `?options=key=value;key=value` and `?optionsB=` to set core options), pick a ROM and run:

- **Determinism**: engine A runs scripted two-player input straight; engine B runs the same input the way a guest's
  rollback session does (player 1's input arrives up to 7 frames late, B repeats the last one it knows, then rolls back
  and runs again when the real one comes). Game memory and picture must match on every frame; the whole state is
  reported too, with the parts that differ named. "real time" runs it at 60 fps to watch, and "control" gives B inputs
  A never sees, which must fail.
- **Timings**: save, load and one frame, measured inside the engine.
- **Stress**: every frame, roll back 8 frames and run them again plus one new frame, at 60 fps, counting the page's
  message round trips.
- **Solo state**: load a core state taken from a RetroArch save state and play on.
- **Save RAM**: write a different pattern to each memory id (Gearsystem's `0x100` and `0x200`) and read them back.

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

pcsx_rearmed with the SCPH1001 BIOS, from power-on (so through the BIOS's boot), the same runs on the same PC
(2026-10-12):

| Game | Frame | State | Stress (8 back, every frame) | Mismatches (game memory, picture) |
| --- | --- | --- | --- | --- |
| Crash Team Racing | 7.3 ms | 4,456,448 B | 17.8 fps, 338% | 1, 0 |
| Spyro the Dragon | 9.0 ms | 4,456,448 B | 17.0 fps, 352% | 0, 1 |
| Resident Evil | 4.8 ms | 4,456,448 B | 17.1 fps, 350% | 0, 0 |

The two mismatches are single frames in the BIOS's boot (Crash Team Racing's frame 305, Spyro's 253); the frames
after them match again. A load takes 1.4 to 1.6 ms. The whole saved state differs on every frame, in a save counter
(see The cores). A PS1 frame costs about five times an SNES one, so eight frames again every frame is far out of
reach; the short rollbacks of a real session fit.

Gearsystem, Super Space Invaders (USA, Europe) in its link game, both consoles of the one core, the same runs on
the same PC (2026-10-15). The scripted inputs press Start, Down and button 1 on both pads to reach LINK GAME, then
play both pads at random for 36,000 frames (10 minutes) with 2,583 rollbacks of engine B (6,643 frames run again):

| Engines | Mismatches (game memory, picture, whole saved state) |
| --- | --- |
| A and B both on console 1 | 0, 0, 0 |
| A on console 1 and B on console 2, as a session's host and guest are | 0, differ by design, 0 |
| Control (B gets inputs A never sees) | fails from the frame the inputs differ, as it must |

Showing and hearing the other console changes the picture and the sound, and nothing in the state. A frame of both
consoles takes 1.2 ms, a save 0.96 ms and a load 2.0 ms (state 862,028 bytes); the stress run (rolling back and running
again every frame, with the page's message round trips) holds 59.8 fps with 2 frames back (55% of the frame's 16.7 ms)
and with 4 back (80%), and 46.8 fps with 8 back (128%, so eight frames every frame is out of reach, as it is for the
SA-1 and PS1; a real session rolls back only as far as an input arrived late). Save RAM reads and writes back by
memory id for each console, 32,768 bytes each. A solo Game Gear state (199,406 bytes) has no second console, so it
loads with the link off; a link state is the engine's own (the host's, sent to the guest).

Super Mario Kart (a DSP-1 game) differs in the whole saved state after rollbacks in the `SP1` block (10,866 of 12,000
frames) while its game memory and picture match on every frame; `rombie-netplay-engine-2026.0.1` does the same, so it
is not from this release.

## Licenses

fceumm and Supafaust are GPL-2.0-or-later; their own copies of the license (`Copying`, `COPYING`) are in the
submodules, and `LICENSES/GPL-2.0.txt` holds the same license's text. The files written for this folder
(`netplay-main.c`, `netplay-worker.js`, `build.sh`, `Dockerfile`, `test.html`, this README) are GPL-2.0-or-later too,
since the engines link GPL cores, and so are the Supafaust and pcsx_rearmed patches. pcsx_rearmed is
GPL-2.0-or-later (its `COPYING`); the parts of it compiled in that are under other licenses are libchdr with its
LZMA, zstd and FLAC decoders (BSD-3-Clause and public domain, notices in `deps/libchdr`) and `gte_divider.c`
(BSD-3-Clause, in its header). zlib, which it reads CHD and PBP images with, is Emscripten's port (zlib License). The libretro-common files compiled in from fceumm's
source are MIT, as their headers say.

Gearsystem is GPL-3.0-or-later (its `LICENSE`, the same text as `LICENSES/GPL-3.0.txt`). Its engine combines it with
this folder's GPL-2.0-or-later files under version 3, so `gearsystem.js` and `.wasm` are GPL-3.0-or-later as a whole,
and the two files in `overlay/` are GPL-3.0-or-later like Gearsystem's own. What it compiles in under other licenses:
Blip_Buffer 0.4.1 and Sms_Snd_Emu 0.1.4 (LGPL-2.1-or-later, `LICENSES/LGPL-2.1.txt`), Stereo_Buffer 0.3.0
(GPL-2.0-or-later), miniz 3.1.2 (MIT, with public-domain parts) and emu2413 1.6.2 (MIT, `LICENSES/emu2413-MIT.txt`).
The YM2413 chip is the part Gearsystem has from Genesis Plus GX, under that project's non-commercial license, and is
not built: `overlay/` and emu2413 take its place, as in `gearsystem/`.
