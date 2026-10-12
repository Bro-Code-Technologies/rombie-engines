# rombie-engines

The source of the engines that [Rombie](https://rombie.brocodetech.com), Bro Code Technologies' browser game
library, builds from open-source projects and serves to its players. Each upstream project is a git submodule
pinned to the exact commit used, beside the build script and any patches, so every file Rombie serves can be
rebuilt from here. Each release attaches a full-source archive that includes the submodules.

## Folders

| Folder | What it builds | Upstream (submodule, commit) | License | Files in Rombie |
| --- | --- | --- | --- | --- |
| `snes/` | RetroArch for Emscripten with Beetle Supafaust, Rombie's SNES emulator | `RetroArch`: [libretro/RetroArch](https://github.com/libretro/RetroArch) `a609b709eb9b5d9a7af89dbf40dd5c673280e636` (1.22.2) · `supafaust`: [libretro/supafaust](https://github.com/libretro/supafaust) `642d1d1b6684aa7e306a02a89885f3f5456a5157` | GPL-3.0-or-later (RetroArch) with GPL-2.0-or-later (Supafaust) | `public/cores/mednafen_supafaust_libretro.js`, `.wasm` |
| `mgba-link/` | mGBA for Rombie's Link Cable engine (two-player link play for Game Boy Color and Game Boy Advance) | `mgba`: [thenick775/mgba](https://github.com/thenick775/mgba) `e974b288bd7e5cfc7c7b96f8b4d32b673ddfb68c` (branch `feature/wasm`) | MPL-2.0 | `public/link-cable/mgba-link.js`, `.wasm` |
| `netplay/` | Rombie's netplay engine: a libretro frontend of Rombie's own, run in a Web Worker, built with one core per file (NES, SNES and PS1) | `fceumm`: [libretro/libretro-fceumm](https://github.com/libretro/libretro-fceumm) `5cd4a43e16a7f3cd35628d481c347a0a98cfdfa2` · `supafaust`: [libretro/supafaust](https://github.com/libretro/supafaust) `642d1d1b6684aa7e306a02a89885f3f5456a5157` · `pcsx_rearmed`: [libretro/pcsx_rearmed](https://github.com/libretro/pcsx_rearmed) `228c14e10e9a8fae0ead8adf30daad2cdd8655b9` | GPL-2.0-or-later | `public/netplay/fceumm.js`, `.wasm`, `supafaust.js`, `.wasm`, `pcsx_rearmed.js`, `.wasm` |

`netplay/`'s own README describes the engine, its messages and its checks.

## Which Rombie release used what

| Rombie | `snes/` | `mgba-link/` | `netplay/` |
| --- | --- | --- | --- |
| 2026.0.9 | `rombie-snes-engine-2026.0.0` | `rombie-link-cable-engine-2026.0.0` | `rombie-netplay-engine-2026.0.1` |
| 2026.0.8 | `rombie-snes-engine-2026.0.0` | `rombie-link-cable-engine-2026.0.0` | `rombie-netplay-engine-2026.0.0` |
| 2026.0.7 | `rombie-snes-engine-2026.0.0` | `rombie-link-cable-engine-2026.0.0` | none |
| 2026.0.0 to 2026.0.6 | none (SNES ran snes9x from jsDelivr) | `rombie-link-cable-engine-2026.0.0` (the same files) | none |

## The files and their SHA-256

`rombie-snes-engine-2026.0.0`:

```
f2d072805fd51de3fd2115e2d0036df99ae5567805b884ed222ad086690c370a  mednafen_supafaust_libretro.wasm
df3497e4fbf0fe148cec20abd42821fdc1aeb98da4c278bfb60036b1f4e23032  mednafen_supafaust_libretro.js
```

`rombie-link-cable-engine-2026.0.0`:

```
3a32363c3b1acb36939b03ca54bdc6cb64f08786fa8c4c0f07d5749d6d5e20f6  mgba-link.wasm
0247b5c54c732eb1577a0f365e3721b2c6d7c21fd7b187fbba0d438e83352cbe  mgba-link.js
```

`rombie-netplay-engine-2026.0.1`:

```
f9b250663b1fac337cc5706865232d66fa7b5c8ec0ac18013ce1e92ed7fa0c3a  fceumm.js
4db3f049d9349e2ad561f6ec0948957acde99631826153399416f53575ae4043  fceumm.wasm
fd099696e526627b276629466e68b6731fc53b0f9211153a8f48817d63798224  supafaust.js
869afb71dc6883c70bcba6575d2ef34768afdcea15be47770528b364a5c3473e  supafaust.wasm
15bac9a448087418c250ff8897da8d6c0075417e8519e938ffaeb16f2a19fe37  pcsx_rearmed.js
59dbc9d7d65246eb1917ebfcef18c89b4db6deff055b085f15e6118249aa7439  pcsx_rearmed.wasm
```

`rombie-netplay-engine-2026.0.0`:

```
a880bff0e28a3ffe31b20af67e62b49bae197ed1fbf7aef77df6a2113082d9cb  fceumm.js
e9ff8cf9b393c8c6842f5c1542da0887844e41c1e3ee72a3df038b49af2a2131  fceumm.wasm
488644f2db259372cd89ce26fa5452721f71c4a2f9913c6b237375b5ea98134d  supafaust.js
56d5d486a5f6e7aaceb2b6276f0c4b5054e58cbba2fa92a2cd65633f3053ec09  supafaust.wasm
```

## Building

Every build runs in Docker, from the repo root, with the submodules checked out
(`git submodule update --init`).

**SNES**

```sh
docker build -t rombie-snes snes
docker run --rm -v "${PWD}:/repo" rombie-snes sh /repo/snes/build.sh
```

The output lands in `snes/out/` with its `SHA256SUMS`, and matches the hashes above byte for byte. The build
follows libretro's own recipe (the core with `platform=emscripten`, linked by RetroArch's `Makefile.emscripten`) in
Emscripten 3.1.46, with:

- `patches/mednafen_supafaust.patch`: on Emscripten, no thread affinity or `sem_timedwait`, and the single-threaded
  renderer, since RetroArch's web build has no threads;
- C++ exceptions as WebAssembly exceptions (`-fwasm-exceptions`) in the core and in RetroArch, since Mednafen throws
  and catches in ordinary control flow;
- RetroArch without 7-Zip support (`HAVE_7ZIP=0`), since Rombie only hands it `.sfc` and `.smc` files.

**Link Cable's mGBA**

```sh
docker build -t local-mgba/wasm:2.0 mgba-link/mgba/src/platform/wasm/docker
docker run --rm --user root -v "${PWD}:/repo" -v "<folder>:/engine:ro" local-mgba/wasm:2.0 sh /repo/mgba-link/build.sh /engine
```

The Link Cable engine is mGBA plus two files of Rombie's own, `link-main.c` and its `CMakeLists.txt`, which hold no
mGBA code and are not in this repo; MPL-2.0 covers mGBA's files, not the larger work. `<folder>` is the folder that
holds those two. `patches/CMakeLists.txt.patch` is the one line added to mGBA's root `CMakeLists.txt` to build
them as a target. With Rombie's two files from the same release, the output matches the hashes above byte for
byte.

**Netplay engine**

```sh
docker build -t rombie-netplay netplay
docker run --rm -v "${PWD}:/repo" rombie-netplay sh /repo/netplay/build.sh
```

The output lands in `netplay/out/` with its `SHA256SUMS`, and matches the latest netplay release's hashes above byte for byte;
`netplay/README.md` has the details.

## Releases

Each engine is released on its own, named like Rombie's PS2 engine: tag `rombie-<engine>-engine-<version>`
(`rombie-snes-engine-2026.0.0` for `snes/`, `rombie-link-cable-engine-2026.0.0` for `mgba-link/`,
`rombie-netplay-engine-2026.0.0` for `netplay/`), release name "Rombie SNES Engine 2026.0.0", "Rombie Link Cable
Engine 2026.0.0" or "Rombie Netplay Engine 2026.0.0". Versions are year-based (`YYYY.N.patch`).
Each release attaches the full-source archive that `make-source-archive.sh` makes: this repo's files for that
folder at the tag, plus its submodules at the pinned commits.

```sh
docker run --rm -v "${PWD}:/repo" -w /repo rombie-snes sh make-source-archive.sh snes rombie-snes-engine-2026.0.0
```

The build scripts also build from an extracted source archive. The SNES and netplay builds then match the hashes
above as well. mGBA's version stamp needs git, so a build from an archive stamps "(unknown)" and its wasm is not byte for
byte the shipped one.

## Licenses

`LICENSES/` holds the full texts: `GPL-3.0.txt` (RetroArch's `COPYING`), `GPL-2.0.txt` (Supafaust's `COPYING`) and
`MPL-2.0.txt` (mGBA's `LICENSE`), each copied from the project at the pinned commit. Every upstream project stays
under its own license. The files written for this repo (build scripts, Dockerfile, patches, this README) are under
the license of what they build: GPL-3.0-or-later in `snes/` and at the root, except the Supafaust patch, which
stays under Supafaust's GPL-2.0-or-later, MPL-2.0 in `mgba-link/`, and GPL-2.0-or-later in `netplay/`, whose engine
links GPL-2.0-or-later cores. fceumm's own copy of its license, `Copying`, is an older printing of `GPL-2.0.txt`.
pcsx_rearmed's `COPYING` is GPL-2.0 as well; the BSD-3-Clause and public-domain parts it compiles in are listed in
`netplay/README.md`.
