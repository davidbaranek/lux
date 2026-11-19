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
- **apps**: both apps built (`Lux-iOS` for the simulator, unsigned; `Lux-Mac` signed ad hoc and
  universal, as Xcode Cloud archives it, so code the Intel slice cannot compile fails here).
  Each build's log is checked for warnings in our sources as well (`scripts/check-build-warnings.sh`):
  a concurrency warning softened by `@preconcurrency` is not promoted to an error.
- **check**: passes when all of them did; it is the one check branch protection requires.

Before a TestFlight build, the smoke test runs by hand: **smoke** runs only when the workflow is
started from the Actions tab (`workflow_dispatch`), and `check` does not wait for it. It walks
through `Apps/UITests/SmokeTests.swift` on a simulator, the demo account (`-LuxDemo`): a chat,
search, Settings, the app sent to the background and back. It fails on a crash or a step that does
not answer within 10 s; a failed run keeps the result bundle and any crash report as the run's
artifact. To run it locally: `xcodebuild test -scheme Lux-iOS -destination 'platform=iOS
Simulator,name=iPhone 17' -only-testing:Lux-iOS-UITests/SmokeTests`.

Photo search's reading by Vision and its model run by hand too, before a release, on a Mac with a
GPU: GitHub's virtual machines read no text, so CI skips them (what photo reading decides without
Vision, `PhotoIndexerReadingTests`, runs on every pull request). `PhotoReaderTests` and
`PhotoIndexerTests` need Vision; `findsAPhotoByHowItLooks`, `findsAMessageByWhatItMeans` and
`findsAShortReplyByTheMessagesBeforeIt` need the model as well (`scripts/image-search/package.sh`
writes it):

```sh
LUX_PHOTO_MODEL=<out>/PhotoSearch swift test --filter 'PhotoReaderTests|PhotoIndexerTests'
```

Each skipped test says why in the test log; on a Mac where Vision reads, none may be skipped.

How search by meaning reads messages (each with the messages before it, as the title of
EmbeddingGemma's document prompt) was chosen on conversations written for it, in Czech and
English: `scripts/image-search/evaluate-messages.py` measures recall@k and MRR of each way of
reading against the model's PyTorch weights (the ones convert.py builds from). Run it after a
change to how messages are read, or to the model, and put its table in the pull request:

```sh
uv run scripts/image-search/evaluate-messages.py 64    # the encoder's length in tokens
uv run scripts/image-search/evaluate-messages.py --similarity
```

The second says how many of the hits the model's `messageSimilarity` keeps, and how much of
the unrelated rest. convert.py measures that threshold on the same conversations
(`scripts/image-search/conversations.py`), read as the app reads them: a change to how messages
are read is a change there too, and its threshold reaches the app with the next pack.

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
  **TestFlight and App Store**. A build archived for TestFlight (Internal Testing Only) can never
  reach external testers, and the App Store Connect API cannot change this setting (the
  workflow's TestFlight post-action is not in it), so set it in Xcode.
- **Post-action:** TestFlight Internal Testing, the internal group.

### External testers

External testers (the `External` group) get a build only after Beta App Review approves it, once
per version (later builds of an approved version usually pass at once). App Store Connect keeps,
under TestFlight › Test Information:

- the beta app description and the "what to test" notes, in English and Czech;
- the feedback email, and a privacy policy URL;
- Beta App Review's contact (name, phone, email) and a demo account: a real Matrix account on a
  homeserver the reviewers can reach, with a few chats. The demo mode (`-LuxDemo`) is a launch
  argument, which a reviewer cannot set. The demo account is `@lux-review:matrix.bardav.com`,
  with chats from `@lux-review-anna` and `@lux-review-tom`; its password lives in 1Password and in
  App Store Connect only, never in the repository.

The privacy policy is [privacy.md](privacy.md), linked from App Store Connect at its GitHub URL on
`dev`.

The `PhotoSearch` asset pack goes through Beta App Review too: its newest version's external beta
release must be `READY_FOR_BETA_SUBMISSION` when the build is submitted
(`betaAppReviewSubmissions` with the build), and should then move to `WAITING_FOR_REVIEW`.
External testers get the pack once it is approved.

Export compliance: `ITSAppUsesNonExemptEncryption` is `NO`. Lux uses only standard encryption
(Matrix's Olm and Megolm, TLS) in a mass-market app, which needs no export documentation in App
Store Connect. Distributing on the App Store in France additionally needs a French encryption
declaration, to be decided before the App Store release.

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
