#!/bin/sh
# Builds RetroArch for Emscripten with Gearsystem (Sega Master System and Game Gear), without the one
# file of Gearsystem's that comes from Genesis Plus GX: the files Rombie serves from its public/cores/.
# It follows libretro's own recipe (ci-templates, emscripten-static.yml): the core is built with
# platform=emscripten, renamed to libretro_emscripten.bc, and linked by RetroArch's Makefile.emscripten.
# Run from the repo root (see README.md):
#   docker build -t rombie-gearsystem gearsystem
#   docker run --rm -v "${PWD}:/repo" rombie-gearsystem sh /repo/gearsystem/build.sh
# Output: gearsystem/out/gearsystem_libretro.js and .wasm, and SHA256SUMS.
#
# GEARSYSTEM_STOCK=1 builds Gearsystem as it is, with its Genesis Plus GX file, into gearsystem/out-stock/.
# It is a control for comparing the two builds' sound, and is never served.
set -eu
REPO=/repo
W=/work
STOCK=${GEARSYSTEM_STOCK:-0}
if [ "$STOCK" = 1 ]; then OUT=$REPO/gearsystem/out-stock; else OUT=$REPO/gearsystem/out; fi
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
for p in gearsystem/RetroArch gearsystem/Gearsystem gearsystem/emu2413; do
  if [ -e "$REPO/$p/.git" ]; then
    head=$(git -C "$REPO/$p" rev-parse HEAD)
    pinned=$(git -C "$REPO" ls-files -s "$p" | awk '{print $2}')
    if [ -n "$pinned" ] && [ "$pinned" != "$head" ]; then
      echo "$p is at $head, but the repo pins $pinned (git submodule update)"; exit 1
    fi
  fi
done

rm -rf "${W:?}"
copy_tree gearsystem/RetroArch "$W/RetroArch"
copy_tree gearsystem/Gearsystem "$W/Gearsystem"
copy_tree gearsystem/emu2413 "$W/emu2413"

if [ "$STOCK" != 1 ]; then
  # Gearsystem's src/audio/emu2413/ holds Genesis Plus GX's ym2413.c under that name. Rombie's two
  # files take its place, and Mitsutaka Okazaki's emu2413 (MIT) goes beside them for them to include.
  CHIP=$W/Gearsystem/src/audio/emu2413
  rm -f "$CHIP/emu2413.c" "$CHIP/emu2413.h"
  mkdir -p "$CHIP/okazaki"
  cp "$W/emu2413/emu2413.c" "$W/emu2413/emu2413.h" "$CHIP/okazaki/"
  cp "$REPO/gearsystem/overlay/src/audio/emu2413/emu2413.c" "$REPO/gearsystem/overlay/src/audio/emu2413/emu2413.h" "$CHIP/"
  echo "YM2413: Rombie's files over Okazaki's emu2413"
else
  echo "YM2413: Gearsystem's own file (control build)"
fi

# RetroArch puts __DATE__ in its version info; fixing the date at RetroArch's commit
# (2025-11-17 13:22:57 UTC) keeps rebuilds byte for byte the same.
export SOURCE_DATE_EPOCH=1763385777

(cd "$W/Gearsystem/platforms/libretro" && emmake make -j"$N" platform=emscripten)
cp "$W/Gearsystem/platforms/libretro/gearsystem_libretro_emscripten.bc" "$W/RetroArch/libretro_emscripten.bc"
# HAVE_7ZIP=0: Rombie hands RetroArch the game's own file only (.sms, .gg), so no .7z support.
(cd "$W/RetroArch" && emmake make -f Makefile.emscripten -j"$N" HAVE_7ZIP=0 LIBRETRO=gearsystem)

rm -rf "${OUT:?}"
mkdir -p "$OUT"
cp "$W/RetroArch/gearsystem_libretro.js" "$W/RetroArch/gearsystem_libretro.wasm" "$OUT/"
(cd "$OUT" && sha256sum gearsystem_libretro.js gearsystem_libretro.wasm | tee SHA256SUMS)
