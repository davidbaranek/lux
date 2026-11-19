#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Builds the apps' library from source: the Rust core (core/) with the Matrix SDK it links, as
# Vendor/LuxFFI.xcframework and its Swift bindings in Vendor/LuxBindings.
# The first build takes several minutes (the SDK compiles too); later ones reuse it.
#
# Outside CI, a build of a committed core/ is kept in a cache shared by every checkout and
# worktree, keyed by what makes it: core/'s tree, the arguments, the Rust toolchain and Xcode.
# A hit fills Vendor/ with a clone (APFS: no extra space) instead of building. A core/ with
# changes not committed is built and not cached. Keys unused for 14 days are removed.
# Clear it with `rm -rf ~/Library/Caches/lux-native/vendor`.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here/core"
cache="${LUX_CORE_CACHE:-$HOME/Library/Caches/lux-native/vendor}"
vendor="$here/Vendor"
outputs="LuxFFI.xcframework LuxBindings"

key=""
if [ -z "${CI:-}${CI_XCODE_CLOUD:-}" ] &&
    tree="$(git rev-parse --verify --quiet HEAD:core)" &&
    [ -z "$(git status --porcelain --untracked-files=all -- .)" ]; then
    key="$(printf '%s\n' "$tree" "$*" "$(rustc -V)" "$(sh "$here/.github/actions/xcode/version.sh")" |
        shasum -a 256 | cut -c1-32)"
fi

if [ -n "$key" ] && [ -d "$cache/$key/LuxFFI.xcframework" ] && [ -d "$cache/$key/LuxBindings" ]; then
    echo "-- Reusing the core built for this tree ($cache/$key)"
    mkdir -p "$vendor"
    for output in $outputs; do
        rm -rf "${vendor:?}/$output"
        cp -c -R "$cache/$key/$output" "$vendor/$output"
    done
    touch "$cache/$key"
    exit 0
fi

cargo xtask apple "$@"

if [ -n "$key" ]; then
    mkdir -p "$cache"
    staging="$(mktemp -d "$cache/.staging.XXXXXX")"
    for output in $outputs; do
        cp -c -R "$vendor/$output" "$staging/$output"
    done
    # another checkout may have stored the same key meanwhile: its copy is as good.
    [ -e "$cache/$key" ] || mv "$staging" "$cache/$key"
    rm -rf "$staging" "$cache/$key/${staging##*/}"
    echo "-- Cached the core as $cache/$key"
    find "$cache" -mindepth 1 -maxdepth 1 -mtime +14 -exec rm -rf {} +
fi
