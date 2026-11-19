# Releasing

Publishing a GitHub release runs `.github/workflows/release.yml`, which runs
the tests, then builds Memoir and attaches `Memoir-<version>.dmg` to the
release. If the tests fail, no DMG is built. When the signing secrets below are
set, the DMG is signed with Developer ID and notarized, so it opens without a
Gatekeeper warning.

Every pull request and push to `main` runs `.github/workflows/ci.yml`: the
unit tests, then a Release build.

## Cutting a release

1. Create a release with a tag like `v0.2.0`, or `v0.2.0-beta.1` with "Set as
   a pre-release" ticked. The version in the app comes from the tag. The
   workflow refuses a prerelease without a `-suffix` and a release with one.
2. Write the release notes.
3. Publish. The DMG shows up on the release once the workflow finishes.

The build number (`CFBundleVersion`) is the workflow run number, so it grows
with every build.

To try the pipeline without a release, run the workflow by hand from the
Actions tab (`gh workflow run release.yml`). The DMG is then a workflow
artifact named `Memoir-0.0.0-dev.<run>`, and the tests are skipped.

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

The workflow runs without any secrets. The app is then signed ad-hoc and
macOS refuses to open it on first launch. To open such a build anyway, go to
System Settings > Privacy & Security and click Open Anyway, or remove the
quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/Memoir.app
```

An ad-hoc signature also changes with every build, so macOS asks for the
microphone and system audio again after each update.

For a DMG that opens without a warning, set up everything below. The workflow
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
Gatekeeper blocks it the same way as an ad-hoc one.

## Runner

Both workflows run on the `xcode-27` image (macOS 27, Xcode 27), which GitHub
still lists as a preview. The project uses the Xcode 27 project format, which
the Xcode 26 on the `macos-26` images can't open. Once a `macos-27` image is
generally available, switch `runs-on` to it.
