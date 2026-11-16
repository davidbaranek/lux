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
xcrun coremlcompiler compile "$model/Encoders.mlpackage" "$root/PhotoSearch" >/dev/null
cp "$model/embeddings.bin" "$model/tokenizer.json" "$model/model.json" "$root/PhotoSearch/"
cp "$here/Manifest.json" "$root/"
(cd "$root" && xcrun ba-package Manifest.json -o "$out/PhotoSearch.aar")
# the same folder, unpacked: what the app reads from the pack (for tests on this Mac).
rm -rf "$out/PhotoSearch"
cp -R "$root/PhotoSearch" "$out/PhotoSearch"
echo "$out/PhotoSearch.aar"
