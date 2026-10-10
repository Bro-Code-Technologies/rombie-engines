#!/bin/sh
# Builds RetroArch for Emscripten with Beetle Supafaust: the SNES files Rombie serves from its
# public/cores/. It follows libretro's own recipe (ci-templates, emscripten-static.yml): the core is
# built with platform=emscripten, renamed to libretro_emscripten.bc, and linked by RetroArch's
# Makefile.emscripten. Run from the repo root (see README.md):
#   docker build -t rombie-snes snes
#   docker run --rm -v "${PWD}:/repo" rombie-snes sh /repo/snes/build.sh
# Output: snes/out/mednafen_supafaust_libretro.js and .wasm, and SHA256SUMS.
set -eu
REPO=/repo
W=/work
OUT=$REPO/snes/out
N=$(nproc)

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

copy_source snes/RetroArch RetroArch
copy_source snes/supafaust supafaust
git -C "$W/supafaust" apply "$REPO/snes/patches/mednafen_supafaust.patch"
echo "applied patches/mednafen_supafaust.patch"

# RetroArch puts __DATE__ in its version info; fixing the date at RetroArch's commit
# (2025-11-17 13:22:57 UTC) keeps rebuilds byte for byte the same.
export SOURCE_DATE_EPOCH=1763385777
# Mednafen throws and catches C++ exceptions in ordinary control flow (for one, its probe for an
# MSU-1 file), so the core is built with WebAssembly's native exceptions. That flag also moves
# setjmp/longjmp to the wasm scheme, and the two schemes cannot be mixed in one link, so RetroArch's
# own objects are built with it too. emcc adds EMCC_CFLAGS to every call it makes.
export EMCC_CFLAGS=-fwasm-exceptions

(cd "$W/supafaust" && emmake make -j"$N" platform=emscripten MEMORY=134217728)
cp "$W/supafaust/mednafen_supafaust_libretro_emscripten.bc" "$W/RetroArch/libretro_emscripten.bc"
# HAVE_7ZIP=0: Rombie hands RetroArch only .sfc and .smc files, so no .7z support, as in the build
# Rombie's core choice was tested with.
(cd "$W/RetroArch" && emmake make -f Makefile.emscripten -j"$N" HAVE_7ZIP=0 LIBRETRO=mednafen_supafaust MEMORY=134217728)

mkdir -p "$OUT"
cp "$W/RetroArch/mednafen_supafaust_libretro.js" "$W/RetroArch/mednafen_supafaust_libretro.wasm" "$OUT/"
(cd "$OUT" && sha256sum mednafen_supafaust_libretro.js mednafen_supafaust_libretro.wasm | tee SHA256SUMS)
