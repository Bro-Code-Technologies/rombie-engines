#!/bin/sh
# Builds RetroArch for Emscripten with Stella (Atari 2600), without the code Stella took from z26: the
# files Rombie serves from its public/cores/. It follows libretro's own recipe (ci-templates,
# emscripten-static.yml): the core is built with platform=emscripten, renamed to libretro_emscripten.bc,
# and linked by RetroArch's Makefile.emscripten.
# Run from the repo root (see README.md):
#   docker build -t rombie-stella stella
#   docker run --rm -v "${PWD}:/repo" rombie-stella sh /repo/stella/build.sh
# Output: stella/out/stella_libretro.js and .wasm, and SHA256SUMS.
set -eu
REPO=/repo
W=/work
OUT=$REPO/stella/out
N=$(nproc)

# Copies a submodule, and every submodule inside it, to a work folder, so the checkout stays clean and a
# Windows checkout's line endings never reach the compiler: from git when the folder is a checked-out
# submodule (exactly the commit its parent pins), as plain files in a release's source archive.
copy_tree() { # repo-path work-dir
  mkdir -p "$2"
  if [ -e "$REPO/$1/.git" ]; then
    head=$(git -C "$REPO/$1" rev-parse HEAD)
    echo "$1 at $head"
    git -C "$REPO/$1" -c core.autocrlf=false archive HEAD | tar -x -C "$2"
    git -C "$REPO/$1" ls-tree -r HEAD | awk '$2 == "commit" {print $3, $4}' | while read -r pinned sub; do
      if [ -e "$REPO/$1/$sub/.git" ]; then
        [ "$(git -C "$REPO/$1/$sub" rev-parse HEAD)" = "$pinned" ] || { echo "$1/$sub is not at $pinned (git submodule update --init --recursive)"; exit 1; }
      fi
      copy_tree "$1/$sub" "$2/$sub"
    done
  elif [ -n "$(ls -A "$REPO/$1" 2>/dev/null)" ]; then
    cp -a "$REPO/$1/." "$2/"
    echo "$1 from the source archive"
  else
    echo "$1 is empty (git submodule update --init)"; exit 1
  fi
}

# The top-level folders are checked against what the repo pins, as snes/build.sh does.
for p in stella/RetroArch stella/stella; do
  if [ -e "$REPO/$p/.git" ]; then
    head=$(git -C "$REPO/$p" rev-parse HEAD)
    pinned=$(git -C "$REPO" ls-files -s "$p" | awk '{print $2}')
    if [ -n "$pinned" ] && [ "$pinned" != "$head" ]; then
      echo "$p is at $head, but the repo pins $pinned (git submodule update)"; exit 1
    fi
  fi
done

rm -rf "${W:?}"
copy_tree stella/RetroArch "$W/RetroArch"
copy_tree stella/stella "$W/stella"

# Stella says it took these from z26, whose GPL version 2 (no "or any later version") cannot be combined
# with RetroArch's GPL-3.0. The patch removes their uses (README.md, and the patch's own header); the files
# go too, so nothing compiled can include them.
git -C "$W/stella" apply "$REPO/stella/patches/stella.patch"
echo "applied patches/stella.patch"
(cd "$W/stella/src/emucore" && rm CartCM.cxx CartCM.hxx CompuMate.cxx CompuMate.hxx KidVid.cxx KidVid.hxx \
  MindLink.cxx MindLink.hxx PointingDevice.cxx PointingDevice.hxx AmigaMouse.hxx AtariMouse.hxx TrakBall.hxx)
echo "removed the z26-derived files"

# RetroArch puts __DATE__ in its version info; fixing the date at RetroArch's commit
# (2025-11-17 13:22:57 UTC) keeps rebuilds byte for byte the same.
export SOURCE_DATE_EPOCH=1763385777
# Stella throws and catches C++ exceptions (loading carts and states), so the core is built with
# WebAssembly's native exceptions, and RetroArch's objects with it too, as snes/ does: the flag also moves
# setjmp/longjmp to the wasm scheme, and the two schemes cannot be mixed in one link.
export EMCC_CFLAGS=-fwasm-exceptions

# Stella's makefile asks git for a commit to put in the version; the work copy is no repository, so it
# finds none and the version stays "7.0c", the same on every rebuild.
(cd "$W/stella/src/os/libretro" && emmake make -j"$N" platform=emscripten)
cp "$W/stella/src/os/libretro/stella_libretro_emscripten.bc" "$W/RetroArch/libretro_emscripten.bc"
# HAVE_7ZIP=0: Rombie hands RetroArch the game's own file only (.a26), so no .7z support.
(cd "$W/RetroArch" && emmake make -f Makefile.emscripten -j"$N" HAVE_7ZIP=0 LIBRETRO=stella)

rm -rf "${OUT:?}"
mkdir -p "$OUT"
cp "$W/RetroArch/stella_libretro.js" "$W/RetroArch/stella_libretro.wasm" "$OUT/"
(cd "$OUT" && sha256sum stella_libretro.js stella_libretro.wasm | tee SHA256SUMS)
