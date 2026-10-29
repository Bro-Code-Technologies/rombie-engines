#!/bin/sh
# Builds RetroArch for Emscripten with ProSystem (Atari 7800): the files Rombie serves from its
# public/cores/. It follows libretro's own recipe (ci-templates, emscripten-static.yml): the core is built
# with platform=emscripten, renamed to libretro_emscripten.bc, and linked by RetroArch's Makefile.emscripten.
# Run from the repo root (see README.md):
#   docker build -t rombie-prosystem prosystem
#   docker run --rm -v "${PWD}:/repo" rombie-prosystem sh /repo/prosystem/build.sh
# Output: prosystem/out/prosystem_libretro.js and .wasm, and SHA256SUMS.
set -eu
REPO=/repo
W=/work
OUT=$REPO/prosystem/out
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
for p in prosystem/RetroArch prosystem/prosystem-libretro; do
  if [ -e "$REPO/$p/.git" ]; then
    head=$(git -C "$REPO/$p" rev-parse HEAD)
    pinned=$(git -C "$REPO" ls-files -s "$p" | awk '{print $2}')
    if [ -n "$pinned" ] && [ "$pinned" != "$head" ]; then
      echo "$p is at $head, but the repo pins $pinned (git submodule update)"; exit 1
    fi
  fi
done

rm -rf "${W:?}"
copy_tree prosystem/RetroArch "$W/RetroArch"
copy_tree prosystem/prosystem-libretro "$W/prosystem-libretro"

# RetroArch puts __DATE__ in its version info; fixing the date at RetroArch's commit
# (2025-11-17 13:22:57 UTC) keeps rebuilds byte for byte the same.
export SOURCE_DATE_EPOCH=1763385777

# ProSystem's makefile asks git for a commit to put in the version; the work copy is no repository, so it
# finds none and the version stays "1.3e", the same on every rebuild.
(cd "$W/prosystem-libretro" && emmake make -j"$N" platform=emscripten)
cp "$W/prosystem-libretro/prosystem_libretro_emscripten.bc" "$W/RetroArch/libretro_emscripten.bc"
# HAVE_7ZIP=0: Rombie hands RetroArch the game's own file only (.a78), so no .7z support.
(cd "$W/RetroArch" && emmake make -f Makefile.emscripten -j"$N" HAVE_7ZIP=0 LIBRETRO=prosystem)

rm -rf "${OUT:?}"
mkdir -p "$OUT"
cp "$W/RetroArch/prosystem_libretro.js" "$W/RetroArch/prosystem_libretro.wasm" "$OUT/"
(cd "$OUT" && sha256sum prosystem_libretro.js prosystem_libretro.wasm | tee SHA256SUMS)
