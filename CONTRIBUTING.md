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
cd .. && swift test
```

`lux-core` does not depend on the SDK, so `cargo test -p lux-core` takes seconds. Use it as the
inner loop. CI runs the three `cargo` checks on every pull request.

`xcodegen generate` writes `Lux.xcodeproj`, the Info.plists and the entitlements from
`project.yml`. Edit `project.yml`, never the generated files.

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
  view models over the demo account. `Apps/UITests` holds only performance tests (XCUITest, on the
  demo with `-LuxDemo`): they measure the launch and scrolling the chat list and a chat.
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
