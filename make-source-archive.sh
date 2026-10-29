#!/bin/sh
# Makes the full-source archive for a release: this repo's files for one folder at the release's
# tag, plus every submodule in that folder at the commit the tag pins. GitHub's own source zip
# leaves the submodules out. Run from the repo root, in the snes image (see README.md):
#   sh make-source-archive.sh snes rombie-snes-engine-2026.0.0  ->  rombie-snes-engine-2026.0.0-source.tar.gz
set -eu
folder=${1:?folder, for example snes}
tag=${2:?release tag, for example rombie-snes-engine-2026.0.0}
name=$tag
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Adds a submodule at the commit its parent pins. Inside ClownMDEmu's libretro core it then adds the submodules nested
# in it the same way (its emulation core and libraries, four deep), which the builds compile. Other submodules' own
# submodules are left out, as the builds do not use them (pcsx_rearmed's gnulib and libpicofe, which a checkout has
# empty).
add_submodule() { # path sha
  git -C "$1" cat-file -e "$2^{commit}" 2>/dev/null || { echo "$1 does not have $2 (git submodule update --init, and --recursive inside a clownmdemu-libretro folder)"; exit 1; }
  git -C "$1" -c core.autocrlf=false archive --prefix="$name/$1/" "$2" | tar -x -C "$tmp"
  echo "$1 at $2"
  case "$1" in
    */clownmdemu-libretro | */clownmdemu-libretro/*) ;;
    *) return 0 ;;
  esac
  list="$tmp/nested-$(echo "$1" | tr '/' '_')"
  git -C "$1" ls-tree -r "$2" | awk '$2 == "commit" {print $3, $4}' > "$list"
  while read -r nested_sha nested_path; do
    add_submodule "$1/$nested_path" "$nested_sha"
  done < "$list"
}

git -c core.autocrlf=false archive --prefix="$name/" "$tag" README.md .gitattributes LICENSES "$folder" | tar -x -C "$tmp"
git ls-tree -r "$tag" -- "$folder" | awk '$2 == "commit" {print $3, $4}' > "$tmp/submodules"
while read -r sha path; do
  add_submodule "$path" "$sha"
done < "$tmp/submodules"

# Handy's lynx/lynxdec.cpp states no license, so Rombie does not hand it out: handy/build.sh leaves it out of the build,
# and the archive leaves it out too.
case "$folder" in
  handy)
    rm "$tmp/$name/handy/libretro-handy/lynx/lynxdec.cpp"
    echo "left out handy/libretro-handy/lynx/lynxdec.cpp (it states no license)"
    ;;
esac

tar -C "$tmp" -czf "$tag-source.tar.gz" "$name"
echo "$tag-source.tar.gz"
