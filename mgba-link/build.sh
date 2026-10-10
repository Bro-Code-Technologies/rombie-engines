#!/bin/sh
# Builds mGBA for Rombie's Link Cable engine: public/link-cable/mgba-link.js and .wasm in Rombie.
# The engine's own two files, link-main.c and its CMakeLists.txt, are Rombie's and are not in this
# repo: they hold no mGBA code, and MPL-2.0 covers mGBA's files, not the larger work they are built
# into. Pass the folder that holds them. Run from the repo root (see README.md), in the image mGBA's
# fork builds from its own Dockerfile at the pinned commit:
#   docker build -t local-mgba/wasm:2.0 mgba-link/mgba/src/platform/wasm/docker
#   docker run --rm --user root -v "${PWD}:/repo" -v "<folder>:/engine:ro" local-mgba/wasm:2.0 sh /repo/mgba-link/build.sh /engine
# Output: mgba-link/out/mgba-link.js and .wasm, and SHA256SUMS.
set -eu
REPO=/repo
ENGINE=${1:?pass the folder holding link-main.c and CMakeLists.txt}
# The path the shipped build was made in; it ends up in the wasm.
W=/home/mgba/src
OUT=$REPO/mgba-link/out
git config --global --add safe.directory '*'

# mGBA stamps its git commit, branch and dirty flag into the build (version.cmake), so the source is
# a git checkout of the pinned commit on the fork's branch name, as the shipped build was. From a
# release's source archive there is no git, and the stamps read "(unknown)".
rm -rf "${W:?}"/* "$W"/.git
if [ -e "$REPO/mgba-link/mgba/.git" ]; then
  pinned=$(git -C "$REPO" ls-files -s mgba-link/mgba | awk '{print $2}')
  git init -q "$W"
  git -C "$W" fetch -q --depth 1 "$REPO/mgba-link/mgba" HEAD
  head=$(git -C "$W" rev-parse FETCH_HEAD)
  if [ -n "$pinned" ] && [ "$pinned" != "$head" ]; then
    echo "mgba-link/mgba is at $head, but the repo pins $pinned (git submodule update)"; exit 1
  fi
  git -C "$W" -c core.autocrlf=false checkout -q -B feature/wasm FETCH_HEAD
  # A tag on the commit becomes mGBA's version string. The fork tags the pinned commit v2.5.1 (a
  # lightweight tag), which the shipped build's clone carried and a shallow submodule lacks; it
  # changes with the pin.
  git -C "$W" tag v2.5.1
  echo "mgba-link/mgba at $head"
else
  cp -a "$REPO/mgba-link/mgba/." "$W/"
  echo "mgba-link/mgba from the source archive"
fi

git -C "$W" apply "$REPO/mgba-link/patches/CMakeLists.txt.patch"
mkdir -p "$W/src/platform/wasm-link"
cp "$ENGINE/link-main.c" "$ENGINE/CMakeLists.txt" "$W/src/platform/wasm-link/"

# -DUSE_PNG=OFF: the image's mawk chokes on libpng's options.awk, and the engine takes no screenshots.
cd "$W" && mkdir -p build-net && cd build-net
emcmake cmake .. -DUSE_PNG=OFF -DCMAKE_BUILD_TYPE=Release
make -j"$(nproc)" mgba-link.js

mkdir -p "$OUT"
cp wasm-link/mgba-link.js wasm-link/mgba-link.wasm "$OUT/"
(cd "$OUT" && sha256sum mgba-link.js mgba-link.wasm | tee SHA256SUMS)
