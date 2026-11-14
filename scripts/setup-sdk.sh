#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Builds the apps' library from source: the Rust core (core/) with the Matrix SDK it links, as
# Vendor/LuxFFI.xcframework and its Swift bindings in Vendor/LuxBindings.
# The first build takes several minutes (the SDK compiles too); later ones reuse it.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here/core"
cargo xtask apple "$@"
