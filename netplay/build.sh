#!/bin/sh
# Builds Rombie's netplay engines: netplay-main.c and netplay-worker.js linked with one libretro
# core each, the files Rombie serves from its public/netplay/. Run from the repo root (see README.md):
#   docker build -t rombie-netplay netplay
#   docker run --rm -v "${PWD}:/repo" rombie-netplay sh /repo/netplay/build.sh
# Output: netplay/out/fceumm.js and .wasm (NES), supafaust.js and .wasm (SNES), pcsx_rearmed.js and
# .wasm (PS1), and SHA256SUMS.
set -eu
REPO=/repo
W=/work
OUT=$REPO/netplay/out
N=$(nproc)
# The core's commit, stamped into its version string as libretro's buildbot does ("(SVN) 5cd4a43").
FCEUMM_COMMIT=5cd4a43

# Each source is copied out of the repo before building, so the checkout stays clean and a Windows
# checkout's line endings never reach the compiler: from git when the folder is a checked-out
# submodule (exactly the commit the repo pins), as plain files in a release's source archive.
copy_source() { # repo-path work-dir
  rm -rf "${W:?}/$2"
  mkdir -p "$W/$2"
  if [ -e "$REPO/$1/.git" ]; then
    head=$(git -C "$REPO/$1" rev-parse HEAD)
    pinned=$(git -C "$REPO" ls-files -s "$1" | awk '{print $2}')
    if [ -n "$pinned" ] && [ "$pinned" != "$head" ]; then
      echo "$1 is at $head, but the repo pins $pinned (git submodule update)"; exit 1
    fi
    git -C "$REPO/$1" -c core.autocrlf=false archive HEAD | tar -x -C "$W/$2"
    echo "$1 at $head"
  elif [ -n "$(ls -A "$REPO/$1" 2>/dev/null)" ]; then
    cp -a "$REPO/$1/." "$W/$2/"
    echo "$1 from the source archive"
  else
    echo "$1 is empty (git submodule update --init)"; exit 1
  fi
}

copy_source netplay/fceumm fceumm
mkdir -p "$W/engine"
cp "$REPO/netplay/netplay-main.c" "$REPO/netplay/netplay-worker.js" "$W/engine/"

# The fceumm commit's date (2025-09-13 00:57:07 UTC), so rebuilds are byte for byte the same.
export SOURCE_DATE_EPOCH=1757725027

# The core as libretro builds it for Emscripten (platform=emscripten: a static object, 32-bit
# colour), which is the build Rombie's solo NES runs. It asks for zlib from outside, but nothing in
# it uses zlib, so the engine links none.
(cd "$W/fceumm" && emmake make -f Makefile.libretro -j"$N" platform=emscripten GIT_VERSION="\" $FCEUMM_COMMIT\"")

# A statically linked core leaves libretro-common's file, memory-stream and string helpers to the
# frontend (RetroArch links its own copy); the engine takes them from the core's copy, the list
# fceumm's Makefile.common builds when it is not statically linked.
LRC=$W/fceumm/src/drivers/libretro/libretro-common
COMMON="compat/compat_posix_string.c compat/compat_snprintf.c compat/compat_strcasestr.c
  compat/compat_strl.c compat/fopen_utf8.c encodings/encoding_utf.c file/file_path.c
  file/file_path_io.c streams/file_stream.c streams/file_stream_transforms.c
  streams/memory_stream.c string/stdstring.c time/rtime.c vfs/vfs_implementation.c"

# One module per core, run in a Worker. Single-threaded: no SharedArrayBuffer, so no
# cross-origin isolation is needed.
mkdir -p "$W/out"
emcc -O3 \
  -I "$LRC/include" \
  "$W/engine/netplay-main.c" "$W/fceumm/fceumm_libretro_emscripten.bc" \
  $(for f in $COMMON; do echo "$LRC/$f"; done) \
  -sENVIRONMENT=worker \
  -sALLOW_MEMORY_GROWTH=1 \
  -sINITIAL_MEMORY=33554432 \
  -sEXPORTED_FUNCTIONS=_malloc,_free \
  -sEXPORTED_RUNTIME_METHODS=FS,UTF8ToString,stringToNewUTF8,HEAPU8,HEAP16 \
  --post-js "$W/engine/netplay-worker.js" \
  -o "$W/out/fceumm.js"

# Beetle Supafaust (SNES), the commit and patch Rombie's solo SNES runs (snes/), so a solo game's
# state loads here. Its own libretro.h predates calls the frontend handles, so the frontend is
# compiled against fceumm's copy of libretro-common; the libretro interface is the same.
copy_source netplay/supafaust supafaust
git -C "$W/supafaust" apply "$REPO/netplay/patches/mednafen_supafaust.patch"
echo "applied patches/mednafen_supafaust.patch"
# The Supafaust commit's date (2026-08-23 12:01:03 UTC).
export SOURCE_DATE_EPOCH=1787486463
# Mednafen throws and catches C++ exceptions in ordinary control flow, so everything in this link is
# built with WebAssembly's native exceptions, as in snes/. emcc adds EMCC_CFLAGS to every call.
export EMCC_CFLAGS=-fwasm-exceptions
(cd "$W/supafaust" && emmake make -j"$N" platform=emscripten)
emcc -O3 -I "$LRC/include" -c "$W/engine/netplay-main.c" -o "$W/engine/netplay-main-supafaust.o"
em++ -O3 \
  "$W/engine/netplay-main-supafaust.o" "$W/supafaust/mednafen_supafaust_libretro_emscripten.bc" \
  -sENVIRONMENT=worker \
  -sALLOW_MEMORY_GROWTH=1 \
  -sINITIAL_MEMORY=67108864 \
  -sEXPORTED_FUNCTIONS=_malloc,_free \
  -sEXPORTED_RUNTIME_METHODS=FS,UTF8ToString,stringToNewUTF8,HEAPU8,HEAP16 \
  --post-js "$W/engine/netplay-worker.js" \
  -o "$W/out/supafaust.js"

# pcsx_rearmed (PS1), the commit libretro's buildbot built for RetroArch 1.22.2 (its core reports
# "r25 228c14e"), which is the build Rombie's solo PS1 runs, so a solo game's state loads here.
# platform=emscripten builds it with no threads, no dynamic recompiler and no asynchronous CD reads.
# It reads CHD and PBP images with zlib, which Emscripten provides as a port. A disc is read from
# the files the page mounts (WORKERFS), never copied whole into memory.
PCSX_COMMIT=228c14e
copy_source netplay/pcsx_rearmed pcsx_rearmed
# A loaded state must run on exactly as the saved one would, for rollback: the patch restores what
# a load otherwise loses (README.md, The cores).
git -C "$W/pcsx_rearmed" apply "$REPO/netplay/patches/pcsx_rearmed.patch"
echo "applied patches/pcsx_rearmed.patch"
# The pcsx_rearmed commit's date (2025-08-16 17:27:41 UTC); its frontend stamps __DATE__.
export SOURCE_DATE_EPOCH=1755365261
# The zlib port's headers are needed when compiling as well as linking.
export EMCC_CFLAGS=-sUSE_ZLIB=1
(cd "$W/pcsx_rearmed" && emmake make -f Makefile.libretro -j"$N" platform=emscripten GIT_VERSION="\" $PCSX_COMMIT\"")
emcc -O3 \
  -I "$LRC/include" \
  "$W/engine/netplay-main.c" "$W/pcsx_rearmed/pcsx_rearmed_libretro_emscripten.bc" \
  -lworkerfs.js \
  -sENVIRONMENT=worker \
  -sALLOW_MEMORY_GROWTH=1 \
  -sINITIAL_MEMORY=134217728 \
  -sEXPORTED_FUNCTIONS=_malloc,_free \
  -sEXPORTED_RUNTIME_METHODS=FS,UTF8ToString,stringToNewUTF8,HEAPU8,HEAP16 \
  --post-js "$W/engine/netplay-worker.js" \
  -o "$W/out/pcsx_rearmed.js"

mkdir -p "$OUT"
cp "$W/out/fceumm.js" "$W/out/fceumm.wasm" "$W/out/supafaust.js" "$W/out/supafaust.wasm" \
  "$W/out/pcsx_rearmed.js" "$W/out/pcsx_rearmed.wasm" "$OUT/"
(cd "$OUT" && sha256sum fceumm.js fceumm.wasm supafaust.js supafaust.wasm pcsx_rearmed.js pcsx_rearmed.wasm | tee SHA256SUMS)
