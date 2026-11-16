# Branches and releases

## Branches

- **`main`** holds what was released. Nobody pushes to it: it changes only through a pull request
  from `dev`, once the checks pass.
- **`dev`** is where development lands. Work happens on a feature branch (`feat/…`, `fix/…`)
  that goes into `dev` by a pull request, once the checks (`check`) pass.

Commits follow [Conventional Commits](https://www.conventionalcommits.org): a type, a scope, one
lowercase line (`fix(ios): …`).

## Checks

GitHub Actions (`.github/workflows/ci.yml`) runs on every pull request into `dev` and `main` and
on pushes to them, so a crash or a broken build shows there rather than in a TestFlight report:

- **core**: the Rust core's formatting, lints and tests.
- **sdk**: the core built for the simulator and the Mac (`scripts/setup-sdk.sh --dev --only
  ios-simulator --only macos`), cached by the core's sources: a change outside `core/` reuses it.
- **swift**: the shared package's tests (`swift test`), then again under Thread Sanitizer.
- **apps**: both apps built (`Lux-iOS` for the simulator, unsigned; `Lux-Mac` signed ad hoc).
- **smoke**: `Apps/UITests/SmokeTests.swift` on a simulator, the demo account (`-LuxDemo`): a
  chat, search, Settings, the app sent to the background and back. It fails on a crash or a step
  that does not answer within 10 s; a failed run keeps the result bundle and any crash report as
  the run's artifact.
- **check**: passes when all of them did; it is the one check branch protection requires.

To run the smoke test locally: `xcodebuild test -scheme Lux-iOS -destination 'platform=iOS
Simulator,name=iPhone 17' -only-testing:Lux-iOS-UITests/SmokeTests`.

TestFlight's archives are built by Xcode Cloud.

## TestFlight

Internal testers get the builds of `dev` that carry a `testflight/*` tag, for iPhone and Mac:

```sh
scripts/testflight.sh    # tags dev's newest commit testflight/<date>.<n> and pushes the tag
```

Xcode Cloud's workflow **TestFlight (internal)** starts on a new `testflight/*` tag. Its
`ci_scripts/ci_post_clone.sh` refuses a tag that is not on `dev`, builds the core for the
platform being archived and generates the project; the workflow archives `Lux-iOS` and `Lux-Mac`
and hands the builds to the internal testing group. Xcode Cloud numbers the builds itself.

The Xcode project is generated from `project.yml` but committed, because Xcode Cloud reads it from
the repository: after editing `project.yml`, run `xcodegen generate` and commit both.

### Setting the workflow up (once)

In Xcode: Product › Xcode Cloud › Create Workflow, for the `Lux-iOS` scheme:

- **Start condition:** Tag Changes, tags beginning with `testflight/`.
- **Environment:** the Xcode the project is developed with.
- **Actions:** Archive `Lux-iOS` (iOS) and Archive `Lux-Mac` (macOS), deployment preparation
  TestFlight (Internal Testing Only).
- **Post-action:** TestFlight Internal Testing, the internal group.

## Crashes from TestFlight

`scripts/crashes.py` lists the crash submissions testers sent since a date, each summed up: the
build, the exception, the termination reason (0xdead10cc, 0x8badf00d… named) and the first frame
in the app's own code.

```sh
scripts/crashes.py --since 2026-11-15          # the last 7 days without --since
scripts/crashes.py --save build/crashes        # also keeps each full log (.ips)
scripts/crashes.py --file Lux-2026-11-16.ips   # a crash report on disk
```

It needs [uv](https://docs.astral.sh/uv/) and an App Store Connect API key (Users and Access ›
Integrations › App Store Connect API, role Developer or more), from the environment only, never
committed:

```sh
export ASC_KEY_ID=…          # the key's id
export ASC_ISSUER_ID=…       # the issuer id above the keys
export ASC_KEY_PATH=~/.appstoreconnect/AuthKey_….p8
```

## Photo search's model

Semantic search (photos by what they show, messages by what they mean) downloads its model as an
Apple-hosted asset pack (`PhotoSearch`, on-demand), which App Store Connect hosts apart from the
builds. Build it from the official EmbeddingGemma 2 weights, then upload `PhotoSearch.aar` and the
`Manifest.json` beside it as a new version of the pack (Transporter, or the App Store Connect API:
a `backgroundAssetVersions` with its `backgroundAssetUploadFiles`, MANIFEST and ASSET); a new
version goes to internal TestFlight testers once processed. A new pack only when the model
changes: the app reads every photo and message again with a new one.

```sh
uv run scripts/image-search/convert.py build/image-search/model
scripts/image-search/package.sh build/image-search/model build/image-search
```

Until App Store Connect has the pack, the app reads only the words in photos. To test the model
locally, serve the pack with `xcrun ba-serve` and set the URL override (Background Assets'
"Testing asset packs locally"); `LUX_PHOTO_MODEL=build/image-search/PhotoSearch swift test` runs
the model's own test.
