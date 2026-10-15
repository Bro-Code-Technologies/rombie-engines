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

# Adds a submodule at the commit its parent pins, then the submodules inside it the same way (clownmdemu's
# core has several, nested four deep; the other folders' submodules have none that the builds use).
add_submodule() { # path sha
  git -C "$1" cat-file -e "$2^{commit}" 2>/dev/null || { echo "$1 does not have $2 (git submodule update --init, and --recursive inside clownmdemu/clownmdemu-libretro)"; exit 1; }
  git -C "$1" -c core.autocrlf=false archive --prefix="$name/$1/" "$2" | tar -x -C "$tmp"
  echo "$1 at $2"
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

tar -C "$tmp" -czf "$tag-source.tar.gz" "$name"
echo "$tag-source.tar.gz"
