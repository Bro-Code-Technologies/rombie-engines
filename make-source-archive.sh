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

git -c core.autocrlf=false archive --prefix="$name/" "$tag" README.md .gitattributes LICENSES "$folder" | tar -x -C "$tmp"
git ls-tree -r "$tag" -- "$folder" | awk '$2 == "commit" {print $3, $4}' > "$tmp/submodules"
while read -r sha path; do
  git -C "$path" cat-file -e "$sha^{commit}" 2>/dev/null || { echo "$path does not have $sha (git submodule update --init)"; exit 1; }
  git -C "$path" -c core.autocrlf=false archive --prefix="$name/$path/" "$sha" | tar -x -C "$tmp"
  echo "$path at $sha"
done < "$tmp/submodules"

tar -C "$tmp" -czf "$tag-source.tar.gz" "$name"
echo "$tag-source.tar.gz"
