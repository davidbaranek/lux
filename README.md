# Lux

Lux is a native [Matrix](https://matrix.org) client for iPhone and Mac. The UIs are UIKit and
AppKit. Everything below them lives in a shared Rust core built on
[matrix-rust-sdk](https://github.com/matrix-org/matrix-rust-sdk).

Lux runs no bridges itself. If your homeserver runs bridges to WhatsApp, Signal, Telegram,
Instagram and other networks (for example the mautrix bridges), Lux shows those chats in one
inbox. Each chat shows the logo of its network.

## Status

Lux is an early, personal project. Nothing has been released, and nothing is on TestFlight or the
App Store. Its author uses it every day on his own homeserver. Expect breaking changes, including
to the data a build keeps on the device. What comes next is in [docs/roadmap.md](docs/roadmap.md).

## Features

- Sign-in with OAuth (Matrix Authentication Service) or a password. End-to-end encryption, with a
  recovery key and device verification.
- One chat list for every network. You can filter it by network, space or label. Chats can be
  pinned, archived, muted or merged, and invitations wait under requests.
- Chats with replies, edits, reactions, formatted text, photos, videos and files, drafts, typing
  indicators and read receipts. Read receipts can be turned off for each chat.
- Reminders, Send Later, saved messages and full-text search. Search uses an encrypted index kept
  on the device.
- Push notifications on iPhone. The notification extension decrypts each message on the device.
- A demo mode with made-up chats, for trying the apps without an account.

## Architecture

```
Apps/iOS, Apps/Mac        the UIs (UIKit, AppKit); the iPhone's background tasks in Apps/iOS/App
Sources/                  Swift glue: calls the core; Keychain, notifications
core/crates/lux-ffi       the boundary to Swift (UniFFI)
core/crates/lux-core      the app's logic and view models, independent of the SDK
core/crates/lux-matrix    lux-core's ports over matrix-rust-sdk
core/crates/lux-store     the encrypted store on the device (SQLCipher)
```

See [docs/architecture.md](docs/architecture.md) for the layers, the folders and how data moves, and
[docs/rust-core.md](docs/rust-core.md) for the core's design and rules.

## Requirements

- A Mac with Apple silicon. The Rust core is built for arm64 only.
- Xcode 27.2 or later. The apps run on iOS 26 and macOS 26 or later.
- [rustup](https://rustup.rs). `core/rust-toolchain.toml` pins the toolchain and its Apple targets,
  and rustup installs them on first use.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew bundle` installs it from the `Brewfile`.

## Build and run

```sh
brew bundle
cd core && cargo xtask apple && cd ..   # the core as Vendor/LuxFFI.xcframework, ~20 min the first time
cp Config/Local.xcconfig.example Config/Local.xcconfig
xcodegen generate
open Lux.xcodeproj
```

- **Faster builds while you work.** `cargo xtask apple --dev --only macos --only ios-simulator`
  builds only the slices you need, with a quicker profile.
- **Signing.** In `Config/Local.xcconfig`, set `DEVELOPMENT_TEAM` to your team id. A fork also
  sets its own `LUX_BUNDLE_ID`, because the default one is registered to the maintainer's team.
- **Push notifications.** These need your own push gateway (Sygnal) in `LUX_PUSH_GATEWAY`. Leave
  it empty to build without push. `Config/Lux.xcconfig` explains each setting.

Run the `Lux-iOS` or `Lux-Mac` scheme. To try Lux without an account, add `-LuxDemo` under the
scheme's *Run › Arguments Passed On Launch*.

## Tests

```sh
cd core && cargo test --workspace                       # the core, against a mock homeserver
cargo xtask apple --dev --only macos && cd .. && swift test   # the Swift glue
```

The `Lux-iOS` scheme's tests are UI and performance tests. They run on the demo in an iOS
simulator. [docs/performance.md](docs/performance.md) explains the numbers they measure.
[CONTRIBUTING.md](CONTRIBUTING.md) has the code style and the commit rules.

## Licence

Lux is licensed under the [GNU General Public License v3.0 only](LICENSE) (`GPL-3.0-only`), with
an [additional permission](APP-STORE-EXCEPTION.md) to be distributed through app stores such as
Apple's App Store, whose terms the GPL alone does not allow.
matrix-rust-sdk is Apache-2.0. The network logos are CC0 or CC BY drawings of their owners'
trademarks, as listed in [docs/network-logos.md](docs/network-logos.md).
