#!/bin/sh
# Builds RetroArch for Emscripten with clownmdemu (Sega Genesis and Sega CD): the files Rombie serves
# from its public/cores/. It follows libretro's own recipe (ci-templates, emscripten-static.yml): the core
# is built with platform=emscripten, renamed to libretro_emscripten.bc, and linked by RetroArch's
# Makefile.emscripten. Run from the repo root (see README.md):
#   docker build -t rombie-clownmdemu clownmdemu
#   docker run --rm -v "${PWD}:/repo" rombie-clownmdemu sh /repo/clownmdemu/build.sh
# Output: clownmdemu/out/ClownMDEmu_libretro.js and .wasm, and SHA256SUMS.
#
# The files are named for the core's own library name, "ClownMDEmu" (what retro_get_system_info reports),
# not its repo name. RetroArch keeps saves and save states in a folder named after the library, and
# Nostalgist looks for them in a folder named after the core it was given; with the same name for both,
# an in-game save and a save state are found without any change to RetroArch's folder settings.
set -eu
REPO=/repo
W=/work
OUT=$REPO/clownmdemu/out
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
    echo "$1 is empty (git submodule update --init --recursive)"; exit 1
  fi
}

# The top-level folders are checked against what the repo pins, as snes/build.sh does.
for p in clownmdemu/RetroArch clownmdemu/clownmdemu-libretro; do
  if [ -e "$REPO/$p/.git" ]; then
    head=$(git -C "$REPO/$p" rev-parse HEAD)
    pinned=$(git -C "$REPO" ls-files -s "$p" | awk '{print $2}')
    if [ -n "$pinned" ] && [ "$pinned" != "$head" ]; then
      echo "$p is at $head, but the repo pins $pinned (git submodule update)"; exit 1
    fi
  fi
done

rm -rf "${W:?}"
copy_tree clownmdemu/RetroArch "$W/RetroArch"
copy_tree clownmdemu/clownmdemu-libretro "$W/clownmdemu-libretro"

# RetroArch puts __DATE__ in its version info; fixing the date at RetroArch's commit
# (2025-11-17 13:22:57 UTC) keeps rebuilds byte for byte the same.
export SOURCE_DATE_EPOCH=1763385777

(cd "$W/clownmdemu-libretro" && emmake make -j"$N" platform=emscripten)
cp "$W/clownmdemu-libretro/clownmdemu_libretro_emscripten.bc" "$W/RetroArch/libretro_emscripten.bc"
# HAVE_7ZIP=0: Rombie hands RetroArch the game's own files only (.md, .gen, .bin, .cue, .iso, .chd), so no
# .7z support.
(cd "$W/RetroArch" && emmake make -f Makefile.emscripten -j"$N" HAVE_7ZIP=0 LIBRETRO=ClownMDEmu)

rm -rf "${OUT:?}"
mkdir -p "$OUT"
cp "$W/RetroArch/ClownMDEmu_libretro.js" "$W/RetroArch/ClownMDEmu_libretro.wasm" "$OUT/"
(cd "$OUT" && sha256sum ClownMDEmu_libretro.js ClownMDEmu_libretro.wasm | tee SHA256SUMS)
