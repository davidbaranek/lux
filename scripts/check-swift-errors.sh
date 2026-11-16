#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Fails on Swift that forces or silently swallows an error: `try!`, `as!`, `fatalError` and
# `preconditionFailure`, and `try?`. An error is thrown up, shown, or logged as an explicit best
# effort (`bestEffort` over `Log.app`), never dropped.
#
# Two forms are fine, and are the only ones: `try? await Task.sleep` (a cancelled sleep is the
# expected end, not a failure) and `fatalError()` in an `@available(*, unavailable)`
# `required init(coder:)`, which the compiler makes impossible to call.
set -eu
cd "$(dirname "$0")/.."

found=$(grep -rnE --include='*.swift' 'try[!?]|as!|fatalError|preconditionFailure' Sources Apps Tests scripts \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|\*)' \
    | grep -vE 'try\? await Task\.sleep' \
    | grep -vE '@available\(\*, unavailable\) required init\??\(coder: NSCoder\) \{ fatalError\(\) \}' \
    || true)

if [ -n "$found" ]; then
    echo "$found"
    echo
    echo "error: Swift that forces or swallows an error (try!, as!, try?, fatalError, preconditionFailure)."
    echo "Throw it up, show it, or log it with bestEffort; see scripts/check-swift-errors.sh."
    exit 1
fi
