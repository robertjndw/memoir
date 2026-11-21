# Releasing

Publishing a GitHub release runs `.github/workflows/release.yml`, which runs
the tests, then builds Memoir and attaches `Memoir-<version>.dmg` to the
release. If the tests fail, no DMG is built and the appcast is left alone.
When the signing secrets below are set, the DMG is signed with Developer ID,
notarized, and added to the [Sparkle](https://sparkle-project.org) appcast at
`https://<owner>.github.io/<repo>/appcast.xml`, so installed copies update
themselves. Notarized releases also update the Homebrew cask.

The appcast is deployed by `.github/workflows/pages.yml`, which rebuilds it
from all releases each time. Every signed release carries an
`appcast-item.json` with the update's signature and size, and the release
notes are read from the release itself. Editing or deleting a release
redeploys the appcast, so fixed release notes reach the update window too. To
redeploy by hand, run `gh workflow run pages.yml`.

There are two channels in that one appcast:

| GitHub release | Tag example     | Appcast channel | Who gets it                                  |
| -------------- | --------------- | --------------- | -------------------------------------------- |
| Prerelease     | `v0.3.0-beta.1` | `beta`          | Users with the Beta update channel turned on |
| Release        | `v0.3.0`        | none (stable)   | Everyone                                     |

The workflow refuses a prerelease without a `-suffix` and a release with one.
The app picks the Beta channel by default when its own version has a suffix,
so anyone who installs a beta DMG stays on the beta channel until they switch
it off in Settings > General > Updates.

Every pull request and push to `main` runs `.github/workflows/ci.yml`: the
unit tests, then a Release build.

## Cutting a release

1. Create a release with a tag like `v0.2.0`, or `v0.2.0-beta.1` with "Set as
   a pre-release" ticked. The version in the app comes from the tag.
2. Write the release notes. They are shown in the update window, rendered from
   Markdown.
3. Publish. The DMG shows up on the release once the workflow finishes.
   Installed copies pick the update up on their next daily check, or straight
   away with Check Now in Settings > General.

The build number (`CFBundleVersion`) is the workflow run number, and that is
what Sparkle compares. Versions in the tag are only for people. So if you ship
a stable `0.2.1` hotfix after `0.3.0-beta.1`, beta users are offered `0.2.1`
too, since it was built later.

Memoir skips scheduled update checks while it is recording, so the update
window never pops up over a meeting. If someone clicks Install and Relaunch
during a recording, the recording is finished and saved before the relaunch.

To try the pipeline without a release, run the workflow by hand from the
Actions tab (`gh workflow run release.yml`). The DMG is then a workflow
artifact named `Memoir-0.0.0-dev.<run>`, the appcast and cask are left alone,
and the tests are skipped.

To build the same DMG locally:

```sh
./scripts/build-dmg.sh 0.2.0      # writes .build/dmg/Memoir-0.2.0.dmg
```

This needs [uv](https://docs.astral.sh/uv/) (`brew install uv`) for
`dmgbuild`. The window layout is in `scripts/dmg/settings.py`, and the
background is drawn by `scripts/dmg/make-background.swift`. If you change one,
check the icon positions still match the other, then regenerate the background:

```sh
swift scripts/dmg/make-background.swift scripts/dmg/background.tiff
```

## Signing

The workflow runs without any secrets. The app is then signed ad-hoc, macOS
refuses to open it on first launch, and the release is not added to the
appcast or the cask. To open such a build anyway, go to
System Settings > Privacy & Security and click Open Anyway, or remove the
quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/Memoir.app
```

An ad-hoc signature also changes with every build, so macOS asks for the
microphone and system audio again after each update.

For a DMG that opens without a warning and reaches installed copies through
Sparkle and Homebrew, set up everything below. The workflow
uses the secrets as soon as they are set.

### 1. Team ID

```sh
gh variable set APPLE_TEAM_ID --body ABCDE12345
```

The team ID is not a secret (it is in the signature of every app you ship),
so it is a repository variable.

### 2. Developer ID certificate

Needs the paid Apple Developer Program.

1. Create a **Developer ID Application** certificate under Certificates,
   Identifiers & Profiles (or Xcode > Settings > Accounts > Manage
   Certificates > + > Developer ID Application).
2. Export it from Keychain Access with its private key as a `.p12` with a
   password.
3. Store both:

   ```sh
   base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_P12_BASE64
   gh secret set DEVELOPER_ID_P12_PASSWORD
   ```

### 3. Notarization API key

In App Store Connect > Users and Access > Integrations > App Store Connect API,
create a team key with the **Developer** role and download the `.p8` file (you
can only download it once).

```sh
gh secret set NOTARY_API_KEY < AuthKey_XXXXXXXXXX.p8
gh secret set NOTARY_KEY_ID      # the key ID, e.g. XXXXXXXXXX
gh secret set NOTARY_ISSUER_ID   # the issuer ID shown above the keys list
```

Without the notarization key the DMG is still signed with Developer ID, but
Gatekeeper blocks it the same way as an ad-hoc one, and it is not added to the
appcast.

### 4. Sparkle signing key

Sparkle rejects any update that isn't signed with this key. Back up the
private key somewhere safe: if you lose it, installed copies can't update
anymore.

Use a separate key for Memoir, not one you already use for another app. That
way a leaked key only affects one app. `generate_keys` keeps keys in the login
keychain by account name, and without `--account` it just prints the key it
already has:

```sh
xcodebuild -resolvePackageDependencies -project Memoir.xcodeproj
bin=$(echo ~/Library/Developer/Xcode/DerivedData/Memoir-*/SourcePackages/artifacts/sparkle/Sparkle/bin)
"$bin/generate_keys" --account memoir                     # prints the public key
"$bin/generate_keys" --account memoir -x sparkle-key.txt  # exports the private key for CI
```

Put the printed public key into `SUPublicEDKey` in `Config/Info.plist`. The
workflow refuses to publish to the appcast while it is still the placeholder.
Then store the private key as a secret and delete the file:

```sh
gh secret set SPARKLE_PRIVATE_KEY < sparkle-key.txt && rm sparkle-key.txt
```

### 5. GitHub Pages

Set Pages to deploy from GitHub Actions:

```sh
gh api -X POST "repos/$(gh repo view --json nameWithOwner -q .nameWithOwner)/pages" -f build_type=workflow
```

Or use Settings > Pages > Source > GitHub Actions.

Release runs deploy from the tag, not from `main`, so the `github-pages`
environment also has to allow tags. The environment only exists after Pages
is turned on:

```sh
gh api -X POST "repos/$(gh repo view --json nameWithOwner -q .nameWithOwner)/environments/github-pages/deployment-branch-policies" \
  -f name='v*' -f type=tag
```

Or add a `v*` tag rule under Settings > Environments > github-pages.

### Forks

`SUFeedURL` and `SUPublicEDKey` in `Config/Info.plist` point at this repo's
appcast. If you ship releases from a fork, change both to your own, or your
builds will update to the ones from this repo.

## Homebrew

Memoir is also a cask in the shared tap
[robertjndw/homebrew-tap](https://github.com/robertjndw/homebrew-tap), in
`Casks/memoir.rb`:

```sh
brew install --cask robertjndw/tap/memoir
```

After the DMG is built, the `homebrew` job in `release.yml` sets `version` and
`sha256` in that file to the new release and pushes the change as
github-actions[bot]. Nothing else in the cask is touched, so edit the rest by
hand in the tap. The file has to exist before the first release, with exactly
one `version` and one `sha256` line.

- Only notarized DMGs are pushed. Homebrew quarantines what it downloads, so
  Gatekeeper would block an ad-hoc or unnotarized build.
- A stable release always updates the cask. A prerelease updates it only while
  there is no stable release yet, so testers can install betas now, but once
  `0.1.0` is out a later beta never replaces it.
- Without the `HOMEBREW_TAP_TOKEN` secret the job logs a warning and skips,
  and the release still succeeds.
- Re-running a release that is already in the cask pushes nothing.

### Tap token

The default workflow token can't write to another repo, so the job needs a
fine-grained personal access token with Contents read and write on
`robertjndw/homebrew-tap` only. The token Archipel uses for the same tap works
here too, so set the same value in this repo:

```sh
gh secret set HOMEBREW_TAP_TOKEN --repo robertjndw/memoir
```

When it expires, renew it once and set it again in every repo that pushes to
the tap, since an expired token only shows up as a failed `homebrew` job.

## Debug builds

Sparkle is not started in Debug builds. They carry build number 1, so every
release would look newer and Sparkle would offer to replace the build you are
working on. Debug builds also have their own bundle ID, so they never share
update settings with the installed copy. Build a DMG with
`scripts/build-dmg.sh` to try updating locally.

## Runner

Both workflows run on the `xcode-27` image (macOS 27, Xcode 27), which GitHub
still lists as a preview. The project uses the Xcode 27 project format, which
the Xcode 26 on the `macos-26` images can't open. Once a `macos-27` image is
generally available, switch `runs-on` to it.
