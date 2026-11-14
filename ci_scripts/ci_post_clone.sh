#!/bin/sh
# Xcode Cloud, after it clones the repository: the Rust core built for the platform the workflow
# archives (it is not in git), and the project generated again from project.yml. TestFlight builds start from a `testflight/*` tag, and
# only from a commit on `dev` (docs/releasing.md).
set -eu
cd "$CI_PRIMARY_REPOSITORY_PATH"

if [ -n "${CI_TAG:-}" ]; then
    git fetch --quiet origin dev
    if ! git merge-base --is-ancestor HEAD FETCH_HEAD; then
        echo "error: $CI_TAG does not point at a commit on dev: TestFlight builds come from dev only." >&2
        exit 1
    fi
fi

brew install xcodegen
# the toolchain core/rust-toolchain.toml names, with the iPhone's target.
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain none
. "$HOME/.cargo/env"
case "${CI_PRODUCT_PLATFORM:-iOS}" in
    macOS) slice=macos ;;
    *) slice=ios ;;
esac
(cd core && cargo xtask apple --only "$slice")

# the team that signs (Xcode Cloud manages the certificates and profiles).
echo "DEVELOPMENT_TEAM = ${LUX_TEAM:-YZX3W2YB4G}" > Config/Local.xcconfig
xcodegen generate
