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
| `stella/` | The Atari 2600 core, a submodule pinned to its commit |
| `patches/stella.patch` | Stella's changes, the same file as `stella/patches/` (see The cores) |
| `prosystem-libretro/` | The Atari 7800 core, a submodule pinned to its commit |
| `patches/prosystem.patch` | ProSystem's changes so a loaded state runs on exactly as the saved one would (see The cores), kept with CRLF where ProSystem's files have it |

### Messages

Every request may carry an `id`, which its reply repeats. A request that fails gets
`{ type: 'error', id, request, message }`. Requests sent before the module has finished compiling wait and run in
order; the engine posts `{ type: 'ready' }` when it is up.

| Request | Reply |
| --- | --- |
| `load { rom, name, files?, options?, devices?, sram?, system? }`: the game's bytes and file name, or for a disc its files as `[{ name, data }]` with `data` a `Blob`, mounted read-only and read as the core asks (never copied whole into memory; `name` is the one to load, a `.cue` names the others); core options as `{ key: value }`, a device per port, save RAM, and files for the core's system folder (a BIOS) as `[{ name, data }]`. The core starts here, once its system folder and options are in place, since some look for their BIOS as they start | `loaded { library, fps, sampleRate, baseWidth, baseHeight, aspectRatio, stateSize, sramSize, frame }` |
| `run { from, inputs, audioFrom?, video?, hashes?, reads? }`: run frames from `from` with the given inputs. When `from` is behind the engine it first rolls back to it from the ring. Sound is kept for frames from `audioFrom` on (default `from`); only the last frame is drawn, unless `video: false` | `ran { frame, video, audio, hashes, memoryHashes, videoHashes, engineMs, reads }`: the next frame to run, the picture `{ width, height, pixels }` (RGBA), the sound (interleaved stereo `Int16Array` buffer), with `hashes: true` three per-frame hash arrays (see below), and with `reads: true`, per port, how many of the core's input reads during these frames found a button held (for `test.html`, to see which ports a core polls) |
| `checksum { frame }` | `checksum { frame, hash }`: the hash of the state before `frame`, or `null` when the ring no longer holds it |
| `save` | `state { frame, data }`: the full state, which is the state before `frame` |
| `loadState { data, frame }` | `stateLoaded { frame }`: the state becomes the state before `frame`, and the ring starts over |
| `sramGet { memory? }` | `sram { data }` (`null` when the game has none) |
| `sramSet { data, memory? }` | `sramSet { written }` |
| `filesGet` | `files { files }`: the files in the core's save folder, as `[{ name, data }]` |
| `filesSet { files }` | `filesSet`: the save folder holds these and nothing else |
| `options { options }` | `options` |
| `device { port, device }` | `device` |
| `reset` | `reset { frame }` |
| `bench { iterations? }` | `bench { stateSize, serializeMs, unserializeMs, frameMs }`, averages measured inside the engine |
| `unload` | `unloaded` |

Buffers in replies are transferred, not copied.

**Save RAM.** `memory` is a libretro memory id, `RETRO_MEMORY_SAVE_RAM` (0) when absent. Gearsystem with its link on
runs two consoles, whose save RAM are `0x100` and `0x200` (0 is the first console's too); every other core has the one.

**Save files.** ClownMDEmu keeps a Sega CD game's backup RAM as files in the core's save folder (`/save`, one `.brm`
per entry the BIOS's backup calls make), not as save RAM, and they are not part of a saved state. `filesGet` and
`filesSet` move them in and out, so Rombie hands them across as it does save RAM.

**Core messages.** A core's log messages go to the Worker's console, which is slow, and a core can send many a frame:
ClownMDEmu sends one for every Sega CD BIOS call, which made a Sega CD frame take 25 ms instead of 3.6. RetroArch prints
none unless its log is verbose; the frontend prints a core's first 64 lines, then only errors.

**Inputs.** `inputs` is an `Int16Array` buffer of 40 values per frame: for each of eight ports, the buttons as
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
Stella exposes only the RIOT's 128 bytes of RAM, and its whole state differs for a frame or two after each rollback
in parts the game never sees (see The cores), so Rombie compares game memory and pictures for the 2600. ProSystem's
whole state comes back exactly after a rollback with Rombie's patch, while its picture can keep a frame the rollback
undid (see The cores), so Rombie compares the whole state for the 7800 and not the picture.

## The cores

| Core | Submodule, commit | License | Built |
| --- | --- | --- | --- |
| fceumm (NES) | `fceumm`: [libretro/libretro-fceumm](https://github.com/libretro/libretro-fceumm) `5cd4a43e16a7f3cd35628d481c347a0a98cfdfa2` | GPL-2.0-or-later | `fceumm.js`, `.wasm` |
| Beetle Supafaust (SNES) | `supafaust`: [libretro/supafaust](https://github.com/libretro/supafaust) `642d1d1b6684aa7e306a02a89885f3f5456a5157` | GPL-2.0-or-later | `supafaust.js`, `.wasm` |
| PCSX ReARMed (PS1) | `pcsx_rearmed`: [libretro/pcsx_rearmed](https://github.com/libretro/pcsx_rearmed) `228c14e10e9a8fae0ead8adf30daad2cdd8655b9` | GPL-2.0-or-later | `pcsx_rearmed.js`, `.wasm` |
| Gearsystem (Master System and Game Gear) | `gearsystem`: [drhelius/Gearsystem](https://github.com/drhelius/Gearsystem) `517ddaaafbab1af7a312c2b6b6f6043275f58500` (3.9.22) · `emu2413`: [digital-sound-antiques/emu2413](https://github.com/digital-sound-antiques/emu2413) `2e4f6f9752f43cc33572c6636ca31a647600732c` (1.6.2) | GPL-3.0-or-later (Gearsystem and the files in `overlay/`) with MIT (emu2413) | `gearsystem.js`, `.wasm` |
| ClownMDEmu (Genesis and Sega CD) | `clownmdemu-libretro`: [Clownacy/clownmdemu-libretro](https://github.com/Clownacy/clownmdemu-libretro) `f8395036544d806ebc68fd110a5621c49991a91d` (v1.6.12), with its own submodules, and `patches/clownmdemu.patch` | AGPL-3.0-or-later (ClownMDEmu, clown68000, clownz80 and the patch) with 0BSD, BSD-3-Clause and MIT libraries | `clownmdemu.js`, `.wasm` |
| Stella (Atari 2600) | `stella`: [stella-emu/stella](https://github.com/stella-emu/stella) `c4016ea4891cb0f90979cb35182214af4c1cb4e7` (7.0c), and `patches/stella.patch` | GPL-2.0-or-later (Stella and the patch) with MIT, LGPL-2.1-or-later and public-domain libraries | `stella.js`, `.wasm` |
| ProSystem (Atari 7800) | `prosystem-libretro`: [libretro/prosystem-libretro](https://github.com/libretro/prosystem-libretro) `8a88014287c7a01cd568067e5a557d0a2b2a051f` (1.3e), and `patches/prosystem.patch` | GPL-2.0-or-later (ProSystem and the patch) with LGPL-2.0 (Ron Fries' TIA and POKEY sound), zlib (CoreTone) and MIT (libretro-common) | `prosystem.js`, `.wasm` |

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
in Master System mode) runs on one console as it does solo. With the link off it is the Master System's engine:
there, as with fceumm, the whole state does not come back exactly after a rollback (a few bytes of sound state the
frames run again leave behind) while game memory and picture do, so Rombie compares those.

ClownMDEmu is the commit and patch Rombie's solo Genesis and Sega CD run (`clownmdemu/` in this repo), so a solo game's
state loads here; its core and libraries are submodules nested inside `clownmdemu-libretro`, which `build.sh` copies at
the commits it pins. `patches/clownmdemu.patch` (the same file as `clownmdemu/patches/`) puts the pads' and multitap
adapters' own state into a saved state: upstream leaves it out, so after a load a six-button pad's strobe count and
an adapter's selected pad were wherever the other timeline left them, and two engines read different buttons. A Sega
CD disc is mounted read-only as PS1's is; the core reads CHD with its own libchdr and carries its own boot ROM, so there
is no BIOS. Its pictures can show stale colours for a few frames after a rollback (the core's colour cache is not part
of a state; it catches up on the game's next palette write) while the state is exact, so Rombie compares the whole
state and not the picture. The state is 1,132,088 bytes.

Stella is the commit and patch Rombie's solo 2600 runs (`stella/` in this repo, from `rombie-stella-engine-2026.0.1`),
so a solo game's state loads here. The state is 1,328 bytes: Stella's own, then the patch's block that keeps the
paddles and the driving controller. `patches/stella.patch` is the same file as `stella/patches/`, and its header lists
it in full: the code Stella took from z26 left out, the build for the browser, the stick turning a paddle and steering
the driving controller, the port devices, a saved state that brings the paddles and the driving controller back, and
the picture read from the new system after a port device starts the game again (before, every frame after a device
changed on a running engine came from the old system's freed picture).
It is built as `stella/` builds it (the z26 classes' files deleted from the work copy, `platform=emscripten`, C++20,
WebAssembly exceptions, which Stella throws and catches loading carts and states), and the frontend is compiled
against fceumm's `libretro.h`.

Stella applies a port device (Joystick 257, Paddles 1281, Driving 1537) by starting the game again at its next frame,
so a state loaded before that frame would be thrown away. Rombie therefore runs one frame after `load` with the 2600's
devices, before it loads any state, and again when the controller changes on a running engine; `test.html` does the
same at load, and the frontend and the Worker are unchanged. Stella
fills RAM and seeds its random numbers from the clock at power-on, so two engines that start on their own differ from
the first frame. A session's guests start from the host's state, and `test.html` starts engine B from engine A's.

A load leaves out two things the frames after it put back, neither of which the game sees. One is the TV jitter
emulation's figures for the last frame: `JitterEmulation::load` clears them as it applies its sensitivity again, and
jitter is off in the libretro core, so they only feed a count. The other is TIA's count of lines that have not changed
(`myLinesSinceChange`), cleared as the load applies the colour settings again. It only lets TIA copy the previous line
instead of drawing it, and keeping it could copy a line from the timeline the rollback left. The whole state therefore
differs on the frame a rollback goes back to and the one after it, while game memory and picture match.

ProSystem is the commit Rombie's solo 7800 runs (`prosystem/` in this repo, which builds it without a patch), so a solo
game's state loads here. It runs with no BIOS, as solo play does: it looks for `7800 BIOS (U).rom` or `(E).rom` in
its system folder, and the engine gives it none. It asks the frontend through `RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE`
whether to save runahead's fast states; the frontend does not answer, so it saves its full state, 49,221 bytes, the
size of a solo save state. It is built as `prosystem/` builds it (`platform=emscripten`) and compiles its own copy of
libretro-common's helpers, so the frontend is compiled against fceumm's `libretro.h` and links nothing more.

Its full state holds the CPU's registers, the cartridge's bank and the first 16 KB of memory, and leaves out two things
the game goes on to depend on, so a rolled-back engine drifted from one that ran straight (Rampage: game memory
differed on 228 of 6,000 frames). One is the CPU's place in its scanline, which carries into the next frame, so after
a load a frame ended at a different instruction. The other is the RIOT's timer and port directions, which games read
through INTIM and INTFLG. `patches/prosystem.patch` keeps both, ten values, behind a marker at the end of the state,
where ProSystem writes nothing, and zero-fills the rest. Neither the state's size nor anything before its end
changes: the unpatched core (solo play) loads a state from this engine and ignores the end, and a state without the
marker (from solo play) leaves the values as they are; both were checked with Rampage. A Souper cartridge's state
fills all 49,221 bytes, so it has no room for them and runs as before. The core's files have CRLF line endings
upstream (but `libretro.c`), so the patch keeps them on those lines, and `.gitattributes` keeps it byte for byte.

What a load still leaves behind is the picture: with display DMA off (a game's scene change), Maria draws nothing,
and the frame shows whatever the last drawn one left, which after a rollback can be from the timeline it undid (3
frames of Rampage's 6,000, the same with and without the patch). The game never sees it, and the whole state is exact,
so Rombie compares the whole state for the 7800 and not the picture, as for ClownMDEmu.

## Building

From the repo root, with the submodules checked out (`git submodule update --init netplay/fceumm netplay/supafaust
netplay/pcsx_rearmed netplay/gearsystem netplay/emu2413 netplay/clownmdemu-libretro netplay/stella
netplay/prosystem-libretro`, then
`git -C netplay/clownmdemu-libretro submodule update --init --recursive`; pcsx_rearmed's own submodules are not needed):

```sh
docker build -t rombie-netplay netplay
docker run --rm -v "${PWD}:/repo" rombie-netplay sh /repo/netplay/build.sh
```

The image is Emscripten 3.1.46, pinned by digest, the same as `snes/`. The output lands in `netplay/out/`, one
`.js` and `.wasm` per core, with their `SHA256SUMS`. Builds are byte for byte the same each time; this source builds:

```
545e20e338ed01412fb8e3b703cc1de81b866d32a97157e272dbfc7dec61ba71  fceumm.js
bc2504d91319f3057bd3886f5212f40f6becb82d8d7e772b9b11f09dee5b102a  fceumm.wasm
a971620743731fd1ff651757e05c7af8c2cac5530e47f0dc6b9b2e95f42d3a19  supafaust.js
60a4fa88228e8cf05619a74739acd98b8e11d31b5a1d1513a63e74317930f78e  supafaust.wasm
ea8c7f349ea04a97171bb2990406b04105424a8b053f94f35a07064c6e40cd79  pcsx_rearmed.js
cda5d2e20ff15aea4ac6b60069306af4c230a30dff5b165ebacb7cdb5bfc63f4  pcsx_rearmed.wasm
cc1ffcfc79531957a3a3daaa338dee677efaff02eaa538ad0c4330615bd80b7d  gearsystem.js
b39f56229acb6c45baa91173e176a2c2316fe53ef8bfd6b86a1b53d8688d5608  gearsystem.wasm
d838fec78e3309b2ac92acea7060e11b2d9d4447c625b0c31ee55bf7bf37ffed  clownmdemu.js
404bb448906c9d9d0947a2047350b8453ec41536ab2d83c49ce9a1d04d1d2c98  clownmdemu.wasm
06bc91a7fda9dfc6ca31dc548c78e1a02798c6ec951563eca5b152e3aa6128a6  stella.js
e5492fd261a96b7dd1b7e8b0483054e5dc0bc935d01fd1a43d97a4be77b52203  stella.wasm
6a9f395fd7ee4cb28c3ca9c3d26137714a7c62d57a63f2b3e18f92de88169e0c  prosystem.js
76a2e45157948b07ef767ae02fb9394951baeee01b2b87ccb977ef0987cd8d4b  prosystem.wasm
```

This is `rombie-netplay-engine-2026.0.3`: the first ten are 2026.0.2's files, unchanged, and Stella's and ProSystem's
four are new. Two builds from the same checkout gave the same fourteen files.

In `rombie-netplay-engine-2026.0.2` every file changed from 2026.0.1: the frontend's save RAM calls take a memory id, it limits
a core's log messages, the Worker script has the save folder messages, and both are built into each core's files.
Two builds from the same checkout gave the same ten files. The NES, SNES and PS1 engines were run again on one game each (Super Mario
Bros. 3 for 12,000 frames, Super Mario Kart for 12,000, Spyro the Dragon for 3,000), and give the results documented
here: game memory and picture match, apart from the one boot frame of Spyro's (frame 253), and the whole saved state
differs where it is said to (NES's sound filter, PS1's save counter, SNES's DSP-1 block).

## Testing

`test.html` checks the engine on its own. Serve this folder over HTTP after building (a Worker will not start from
`file://`), for example `python -m http.server 8642` here, open `http://localhost:8642/test.html` (the NES engine;
`test.html?engine=out/supafaust.js` for SNES; `?engine=out/pcsx_rearmed.js` for PS1, picking all of a disc's files and a BIOS; `?engine=out/gearsystem.js` for a Game Gear game's link, with the link on and engine B on the second console as a session's guest has it (`?options=gearsystem_link_enable=Disabled` for a Master System game); `?engine=out/clownmdemu.js` for Genesis or a Sega CD disc (`?options=clownmdemu_input_protocol=ea` or `=sega` for a multitap adapter); `?engine=out/stella.js` for a 2600 game, with `?devices=` giving the port devices (`257,257` joysticks, `1281,1281` paddles, `1537,1537` driving controllers), `?stick=1` moving each scripted player's left stick as well, and `?ports=` scripting up to eight players (`4` for four paddles, `8` for two multitaps); `?engine=out/prosystem.js` for a 7800 game; `?options=key=value;key=value` and `?optionsB=` to set core options, and `?scriptFrames=` to keep a longer run's input script, so a shorter run stops partway through the same play), pick a ROM and run:

- **Determinism**: engine A runs scripted two-player input straight (`?ports=` for more); engine B runs the same input
  the way a guest's rollback session does (every scripted player's input arrives up to 7 frames late, B repeats the
  last it knows, then rolls back and runs again when the real one comes). Game memory and picture must match on every
  frame; the whole state is reported too, with the parts that differ named. It ends with how many of A's input reads
  found a button held on each port, which must be some on every scripted port. "real time" runs it at 60 fps to watch,
  and "control" gives B inputs A never sees, which must fail.
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
is not from this release. With the final files (the log limit and the save folder messages) Super Mario Bros. 3, Super
Mario Kart and Sonic The Hedgehog (Master System, link off) were run again for 6,000 frames each: game memory and
picture matched on every frame, and the whole state differed only where it is said to.

ClownMDEmu, 6,000 frames each (about 420 rollbacks), the same runs on the same PC (2026-10-16):

| Game | Pads | Mismatches (game memory, whole saved state) |
| --- | --- | --- |
| Sonic & Knuckles | standard | 0, 0 |
| Gauntlet IV | EA 4 Way Play | 0, 0 |
| Gauntlet IV | Sega Team Player | 0, 0 |
| Mega Bomberman | Sega Team Player | 0, 0 |
| Dungeon Explorer (Sega CD, `.chd`) | standard | 0, 0 |
| General Chaos | standard | 0, 23 (passing; the final states match) |
| General Chaos | EA 4 Way Play | 1,972 from frame 3,791 |

Without the patch, General Chaos with EA 4 Way Play differed in game memory from frame 110. With it, one difference is
left: after some replays the 68000 ends a frame with a different count of cycles carried into the next (the
`state.sync` bytes), which catches up a frame later; the game's EA 4 Way Play reads, which time out by the
microsecond, sometimes notice. Rombie's checks find that and start the guests again from the host's state. A frame
takes 1.5 ms for a cartridge and 3.6 ms for the Sega CD disc; the stress run holds 59.6 fps for Sonic & Knuckles
(77% of the frame) and 31.4 fps for Dungeon Explorer (191%, so the Sega CD cannot run eight frames again every frame;
a real session's short rollbacks fit).

Stella, 6,000 frames each (426 to 446 rollbacks), engine B starting from engine A's state, the same runs on the same
PC (2026-11-16). The test ROM is a 4 KB one written for these checks that draws the 2600's input registers as stripes:

| Game | Controller | Frame | Stress (8 back, every frame) | Mismatches (game memory, picture, whole saved state) |
| --- | --- | --- | --- | --- |
| Test ROM | joysticks | 0.65 ms | 60.0 fps, 43% | 0, 0, 847 |
| Test ROM | paddles, on the keys | | | 0, 0, 847 |
| Kaboom! | paddles, on the keys | 0.94 ms | 60.0 fps, 65% | 0, 0, 847 |
| Kaboom! | paddles, on the stick | | | 0, 0, 886 |
| Indy 500 | driving controllers, on the keys | | | 0, 0, 847 |
| Indy 500 | driving controllers, on the stick | 1.3 ms | 60.0 fps, 68% | 0, 0, 886 |
| Warlords | four paddles, on the stick | 1.1 ms | 59.9 fps, 71% | 0, 0, 886 |
| Control (B gets inputs A never sees) | joysticks | | | fails from frame 3,000, as it must |

The whole state differs only where a load leaves it out (see The cores): a load followed by a save gives back the same
bytes but for those, with each controller, and the final states match. A save takes 12 us and a load 16 us (state
1,328 bytes). A solo state from `rombie-stella-engine-2026.0.1` (Paddles, with the patch's block) loads with
`?devices=1281,1281`, draws its first frame and plays on. A port device changed on a running engine (Paddles or
Joysticks after 10 or 600 frames, then 120 or 600 frames more) draws the whole picture, as a plain reset does; before
the patch's part 6 it drew only the test ROM's last 8 columns.

ProSystem, 6,000 frames each (426 rollbacks), the same runs on the same PC (2026-11-16). The test ROM is a 7800 one
written for these checks that draws the input registers as stripes, two-button mode:

| Game | Players | Frame | Stress (8 back, every frame) | Mismatches (game memory, picture, whole saved state) |
| --- | --- | --- | --- | --- |
| Rampage | 2 | 0.40 ms | 59.7 fps, 29% | 0, 3, 0 (without the patch: 228 from frame 838, 3, 863) |
| Test ROM | 2 | 0.42 ms | 60.0 fps, 11% | 0, 0, 0 (the same without the patch) |
| Control (B gets inputs A never sees), Rampage | 2 | | | fails from frame 3,001, as it must |

The final states match in every run. A save takes 5 to 11 us and a load 12 to 21 us (49,221 bytes). A solo Rampage
state from `rombie-prosystem-engine-2026.0.0`, in play, loads, draws its first frame and plays on, and a state this
engine saved loads on that unpatched core and plays on.

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

ClownMDEmu (with clown68000 and clownz80) is AGPL-3.0-or-later (its `LICENCE.txt`, the same text as
`LICENSES/AGPL-3.0.txt`). Its engine combines it with this folder's GPL-2.0-or-later files under version 3, which the
AGPL allows, so `clownmdemu.js` and `.wasm` are AGPL-3.0-or-later as a whole, and so is `patches/clownmdemu.patch`.
What it compiles in under other licenses is listed in the repo's README: clowncommon, clownresampler and clowncd
(0BSD), libchdr (BSD-3-Clause) with its LZMA SDK (public domain), miniz (MIT) and Zstandard decoder (BSD-3-Clause), the
Mega CD boot ROM (0BSD) and libretro-common's headers (MIT).

Stella is GPL-2.0-or-later (its `Copyright.txt`: "either version 2 of the License, or any later version"; its
`License.txt` is the GPL-2.0 text, as `LICENSES/GPL-2.0.txt`), and so is `patches/stella.patch`. The code Stella took
from z26, which is GPL version 2 only, is left out, as in `stella/`. Its engine compiles in what `stella/`'s does,
under their own licenses: JSON for Modern C++ 3.11.3 (MIT), Blargg's NTSC filter (LGPL-2.1-or-later), RSA Data
Security's MD5 code (its own notice, in `MD5.hxx`), David Welch's Thumbulator (public domain) and `libretro.h` (MIT).

ProSystem is GPL-2.0-or-later (each `core/` file: "either version 2 of the License, or (at your option) any later
version"; its `License.txt` is an older printing of `LICENSES/GPL-2.0.txt`), and so is `patches/prosystem.patch`. Its
engine compiles in what `prosystem/`'s does, under their own licenses: Ron Fries' TIA and POKEY sound (version 2 of the
GNU Library General Public License, whose section 3 lets them go under the GPL; their legend stays in the source),
Osman Celimli's CoreTone (zlib, `LICENSES/bupboop-zlib.txt`) and libretro-common (MIT).
