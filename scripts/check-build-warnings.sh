#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Fails on a compiler warning in the project's own sources, read from an xcodebuild log:
#
#     xcodebuild build … 2>&1 | tee build/app.log; sh scripts/check-build-warnings.sh build/app.log
#
# SWIFT_TREAT_WARNINGS_AS_ERRORS does not promote every warning: a concurrency diagnostic that
# `@preconcurrency` softened (a non-Sendable function converted to `@Sendable` against a SwiftUI
# `Binding`, say) stays a warning, and the build passes. Generated and third-party code (Vendor/,
# packages, DerivedData) and Xcode's own tools (appintentsmetadataprocessor) are not ours.
set -eu
log="$1"
root="$(cd "$(dirname "$0")/.." && pwd)"

found=$(grep -E '^/.*: warning: ' "$log" \
    | grep -F "$root/" \
    | grep -vE "^$root/(Vendor|build|core/target|\.build)/|/DerivedData/|/SourcePackages/" \
    | grep -v 'appintentsmetadataprocessor' \
    | sort -u || true)

if [ -n "$found" ]; then
    echo "$found"
    echo
    echo "error: the build has warnings in the project's sources (above); fix them, they are not promoted to errors."
    exit 1
fi
