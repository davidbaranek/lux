#!/bin/sh
# Sends dev's newest commit to the internal testers: tags it `testflight/<date>.<n>` and pushes the
# tag; Xcode Cloud builds it and hands it to TestFlight (docs/releasing.md).
set -eu
git fetch --quiet origin dev --tags
commit=$(git rev-parse origin/dev)
day=$(date +%Y.%m.%d)
n=1
while git rev-parse -q --verify "refs/tags/testflight/$day.$n" >/dev/null; do n=$((n + 1)); done
tag="testflight/$day.$n"
git tag -a "$tag" -m "TestFlight $day.$n" "$commit"
git push origin "refs/tags/$tag"
echo "$tag -> $(git log -1 --format='%h %s' "$commit")"
