#!/bin/sh
# Builds RetroArch for Emscripten with Handy (Atari Lynx), without its emulated boot ROM's loader decryption: the
# files Rombie serves from its public/cores/. It follows libretro's own recipe (ci-templates,
# emscripten-static.yml): the core is built with platform=emscripten, renamed to libretro_emscripten.bc, and linked
# by RetroArch's Makefile.emscripten.
# Run from the repo root (see README.md):
#   docker build -t rombie-handy handy
#   docker run --rm -v "${PWD}:/repo" rombie-handy sh /repo/handy/build.sh
# Output: handy/out/handy_libretro.js and .wasm, and SHA256SUMS.
set -eu
REPO=/repo
W=/work
OUT=$REPO/handy/out
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
for p in handy/RetroArch handy/libretro-handy; do
  if [ -e "$REPO/$p/.git" ]; then
    head=$(git -C "$REPO/$p" rev-parse HEAD)
    pinned=$(git -C "$REPO" ls-files -s "$p" | awk '{print $2}')
    if [ -n "$pinned" ] && [ "$pinned" != "$head" ]; then
      echo "$p is at $head, but the repo pins $pinned (git submodule update)"; exit 1
    fi
  fi
done

rm -rf "${W:?}"
copy_tree handy/RetroArch "$W/RetroArch"
copy_tree handy/libretro-handy "$W/libretro-handy"

# lynx/lynxdec.cpp, the loader decryption of Handy's emulated boot ROM, states no license, so the build leaves it out
# and a cart needs the player's lynxboot.img (README.md, and the patch's own header). The file goes too, so nothing
# compiled can include it.
git -C "$W/libretro-handy" apply "$REPO/handy/patches/handy.patch"
echo "applied patches/handy.patch"
rm "$W/libretro-handy/lynx/lynxdec.cpp"
echo "removed lynx/lynxdec.cpp"

# RetroArch puts __DATE__ in its version info; fixing the date at RetroArch's commit
# (2025-11-17 13:22:57 UTC) keeps rebuilds byte for byte the same.
export SOURCE_DATE_EPOCH=1763385777

# Handy's makefile asks git for a commit to put in the version; the work copy is no repository, so it
# finds none and the version stays "0.97", the same on every rebuild.
(cd "$W/libretro-handy" && emmake make -j"$N" platform=emscripten)
cp "$W/libretro-handy/handy_libretro_emscripten.bc" "$W/RetroArch/libretro_emscripten.bc"
# HAVE_7ZIP=0: Rombie hands RetroArch the game's own file only (.lnx), so no .7z support.
(cd "$W/RetroArch" && emmake make -f Makefile.emscripten -j"$N" HAVE_7ZIP=0 LIBRETRO=handy)

rm -rf "${OUT:?}"
mkdir -p "$OUT"
cp "$W/RetroArch/handy_libretro.js" "$W/RetroArch/handy_libretro.wasm" "$OUT/"
(cd "$OUT" && sha256sum handy_libretro.js handy_libretro.wasm | tee SHA256SUMS)
