#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Launch to first chats shown, and the footprint then, as the app logs it (Signposts.firstChatsShown).
# usage: scripts/measure-launch.sh mac|ios [runs] [-LuxDemo]   (ios: SIMULATOR=<udid>)
# BUNDLE_ID: the app's (Config/Lux.xcconfig's LUX_BUNDLE_ID, its log subsystem too).
# DERIVED_DATA: where the Mac build is (the in-tree DerivedData/), CONFIG: its configuration.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
platform="$1"; runs="${2:-5}"; demo="${3:-}"
bundle="${BUNDLE_ID:-com.bardav.lux.native}"
derived="${DERIVED_DATA:-$here/DerivedData}"
predicate="subsystem == \"$bundle\" AND category == \"metrics\""
for i in $(seq "$runs"); do
    if [ "$platform" = mac ]; then
        pkill -x Lux 2>/dev/null || true; sleep 1
        open -n "$derived/Build/Products/${CONFIG:-Release}/Lux.app" --args $demo
        sleep "${WAIT:-6}"
        /usr/bin/log show --last "${WAIT:-6}s" --style compact --predicate "$predicate" | grep -o 'launch-to-first-chats.*' | tail -1
    else
        xcrun simctl terminate "$SIMULATOR" "$bundle" 2>/dev/null || true; sleep 1
        xcrun simctl launch "$SIMULATOR" "$bundle" $demo >/dev/null
        sleep "${WAIT:-6}"
        xcrun simctl spawn "$SIMULATOR" log show --last "${WAIT:-6}s" --style compact --predicate "$predicate" | grep -o 'launch-to-first-chats.*' | tail -1
    fi
done
