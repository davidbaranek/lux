#!/bin/sh
# The selected Xcode's build version (27B52): part of cache keys built with it.
xcodebuild -version | awk '/Build version/ { print $3 }'
