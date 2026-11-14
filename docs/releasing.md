# Branches and releases

## Branches

- **`main`** holds what was released. Nobody pushes to it: it changes only through a pull request
  from `dev`, once the core's checks pass.
- **`dev`** is where development lands. Work happens on a feature branch (`feat/…`, `fix/…`)
  that goes into `dev` by a pull request, once the core's checks (`core`) pass.

Commits follow [Conventional Commits](https://www.conventionalcommits.org): a type, a scope, one
lowercase line (`fix(ios): …`).

## Checks

GitHub Actions runs the Rust core's formatting, lints and tests on every pull request and on
pushes to `dev` and `main` (`.github/workflows/core.yml`). The apps are built by Xcode Cloud.

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
