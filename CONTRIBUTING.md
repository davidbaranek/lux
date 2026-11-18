# Contributing

Thank you for looking. Lux is a small project: open an issue before a large change, so we can
agree on the approach first.

## Build and test

Set up the project as described in the [README](README.md#build-and-run). Then:

```sh
cd core
cargo fmt --all
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cargo xtask apple --dev --only macos    # after a change the Swift side sees
cd .. && sh scripts/check-swift-errors.sh && swift test
```

`lux-core` does not depend on the SDK, so `cargo test -p lux-core` takes seconds. Use it as the
inner loop. CI runs the three `cargo` checks, `check-swift-errors.sh`, the Swift tests (also under
Thread Sanitizer), both apps' builds and the Mac app's view tests on every pull request. What needs a simulator (the
iPhone app's view tests, the smoke test) runs only by hand, before a TestFlight build: from the Actions tab (`workflow_dispatch`) or locally
(docs/releasing.md). So do the photo search tests that need Vision or its model, which CI's
virtual machines cannot run (docs/releasing.md says how).

`xcodegen generate` writes `Lux.xcodeproj`, the Info.plists and the entitlements from
`project.yml`. Edit `project.yml`, never the generated files, and commit the regenerated project
with it (Xcode Cloud builds from the committed project).

## Layering

- The UI (`Apps/`) never sees a generated binding type, and the Swift glue (`Sources/`) is the
  only Swift code that calls the core.
- `lux-core` never names the SDK. It declares ports (traits), and `lux-matrix` implements them.
- Logic that both apps need belongs in the core, not in two copies of Swift.

[docs/architecture.md](docs/architecture.md) says where things live.

## Code style

- **Rust:** edition 2024, `rustfmt` (`core/rustfmt.toml`), and clippy's pedantic lints with
  `-D warnings`. Errors are typed (`thiserror`). No `unwrap` or `expect` outside tests. Public
  items are documented. The full rules are in [docs/rust-core.md](docs/rust-core.md).
- **Swift:** Swift 6 language mode with complete strict concurrency and zero warnings. UI and
  models are `@MainActor`, and only `Sendable` values cross threads. No force unwraps.
  No `try!`, `as!`, `fatalError` or `try?`: an error is thrown up, shown (`onError`, `report`), or
  logged as a best effort (`bestEffort`). `scripts/check-swift-errors.sh` checks it, in CI too.
  `@unchecked Sendable` and `nonisolated(unsafe)` are a last resort, each with a comment saying
  why it is safe.
- Comments explain why, not what. Keep files and functions small, and remove layers that only
  forward a call.

## Tests

- Test behaviour, not implementation. Drive what a user or the next layer can observe (intents in,
  state out), not private fields or the order of internal calls. A refactor that keeps the
  behaviour must not break a test.
- Rust: integration tests in each crate's `tests/` through the public API, against
  `matrix-sdk-test`'s mock server. Unit tests beside the code only for pure rules such as diffs and
  parsing.
- Swift: Swift Testing (`@Test`, `#expect`) for new tests. The main flows are tested through the
  view models over the demo account. `Apps/UITests` holds the XCUITests, on the demo with
  `-LuxDemo`: the smoke test (`SmokeTests`, a walk through the app that fails on a crash or a hang)
  and the performance tests (`PerformanceTests`: the launch, and scrolling the chat list and a
  chat). Both run by hand: the smoke test before a TestFlight build, from the Actions tab or
  locally.
- Views: `Apps/ViewTests` holds the view controllers' tests (Swift Testing), in two bundles the
  apps host, `Lux-iOS-Tests` and `Lux-Mac-Tests`, each with its scheme. A test makes a controller
  over a demo session of its own (`DemoAccount`), loads its view and reads what UIKit or AppKit
  shows, never the controller's private state: a list's diffable snapshot, its cells, how an update
  reached them (the rules in [AGENTS.md](AGENTS.md)), and where a chat opens. Nothing is put in a
  window or drawn, and the tests wait on the model's and the views' announcements (`Changes`,
  key-value observing, view notifications), so they need no GPU. The app hosting them runs the demo
  (`-LuxDemo`, set by the schemes), never the account saved on the machine. CI runs the Mac's on
  every pull request, and the iPhone's only by hand (the runner's simulator is too slow beside the
  hosting app's own demo); locally:

  ```sh
  xcodebuild test -scheme Lux-Mac-Tests -destination 'platform=macOS'
  xcodebuild test -scheme Lux-iOS-Tests -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
  ```

  A Lux already running on the Mac with the same bundle id (a TestFlight build) keeps the Mac's
  test host from launching (LaunchServices error -10699): quit it, or build the tests under
  another id, `LUX_BUNDLE_ID=com.example.lux.tests`.
- Name a test after the behaviour it checks, for example "a muted chat sends no notification".
  Await the observable change with a timeout, never a sleep.
- Test with a test account on a test server, never a personal one. Bridges pass read receipts,
  reactions and messages on to real people.

## Commits and pull requests

- Work on a branch of `dev` (`feat/…`, `fix/…`) and open the pull request into `dev`; `main`
  takes only `dev`, by a pull request. [docs/releasing.md](docs/releasing.md) has the branches
  and how a build reaches TestFlight.
- Commits are conventional, lowercase, scoped and one line, in the imperative. For example:
  `fix(mac): keep the read message in place when older ones load`. Make one change per commit.
- Common scopes: `core`, `matrix`, `store`, `ffi`, `xtask`, `ios`, `mac`, `apps` (both), `push`,
  `docs`, `repo`.
- A pull request includes tests for what it changes. If it touches a hot path (the chat list, the
  thread, launch, images), it also includes the numbers from
  [docs/performance.md](docs/performance.md), before and after.

## Design notes

These live in [`docs/`](docs):

- `architecture.md` maps the code and explains its mechanisms.
- `rust-core.md` covers the core's shape and rules.
- `performance.md` explains how to measure.
- `roadmap.md` lists what comes next.
- `network-logos.md` gives the sources and licences of the logos.

Update the relevant note in the same pull request as the change.

## Licence of contributions

Lux is `GPL-3.0-only` with an [additional permission](APP-STORE-EXCEPTION.md) for app stores. By
submitting a contribution you license it under the same terms, the additional permission
included, so the app can go on shipping through the App Store.
