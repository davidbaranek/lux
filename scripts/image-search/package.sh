#!/bin/sh
# Builds photo search's asset pack (PhotoSearch.aar) for App Store Connect, from the model that
# convert.py writes:
#
#     uv run scripts/image-search/convert.py build/image-search/model
#     scripts/image-search/package.sh build/image-search/model build/image-search
#
# The pack holds the encoders compiled for Core ML (Encoders.mlmodelc, its functions "image" and
# "text": the app loads them as they are),
# the tokenizer and model.json, in a folder PhotoSearch/ (as PhotoSearchAssets reads it).
# Upload the .aar to App Store Connect (Transporter); for a local test, serve it with
# `xcrun ba-serve` (developer.apple.com/documentation/backgroundassets/testing-asset-packs-locally).
set -eu
model=$1
out=$2
here=$(cd "$(dirname "$0")" && pwd)
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/PhotoSearch" "$out"
# ba-package runs in $root: the pack's path from here, whole.
out=$(cd "$out" && pwd)
xcrun coremlcompiler compile "$model/Encoders.mlpackage" "$root/PhotoSearch" >/dev/null
cp "$model/embeddings.bin" "$model/tokenizer.json" "$model/model.json" "$root/PhotoSearch/"
# model.json says which files it came with ("content", the digest of all the others): the app
# keeps its copy of the model under model.json's digest, so a pack whose files changed in any way
# is copied again (PhotoSearchAssets).
content=$(cd "$root/PhotoSearch" && find . -type f ! -path ./model.json -print0 | LC_ALL=C sort -z \
    | xargs -0 shasum -a 256 | shasum -a 256 | cut -c1-64)
plutil -replace content -string "$content" "$root/PhotoSearch/model.json"
cp "$here/Manifest.json" "$root/"
(cd "$root" && xcrun ba-package Manifest.json -o "$out/PhotoSearch.aar")
# the same folder, unpacked: what the app reads from the pack (for tests on this Mac).
rm -rf "$out/PhotoSearch"
cp -R "$root/PhotoSearch" "$out/PhotoSearch"
echo "$out/PhotoSearch.aar"
