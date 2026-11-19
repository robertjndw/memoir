#!/bin/bash
# Builds a Release Memoir.app and packs it into a drag-to-install DMG, laid
# out by scripts/dmg/settings.py. Used by .github/workflows/release.yml, and
# runnable locally. Needs uv (brew install uv) to run dmgbuild.
#
#   ./scripts/build-dmg.sh <version> [build-number]
#
# Signing depends on the environment:
#   SIGNING_IDENTITY  e.g. "Developer ID Application". Unset means an ad-hoc
#                     signature, which Gatekeeper blocks on other Macs until
#                     the user allows it in System Settings > Privacy & Security.
#   DEVELOPMENT_TEAM  the Apple team ID that owns SIGNING_IDENTITY.
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID
#                     an App Store Connect API key. When set (and signing with
#                     Developer ID), the app and DMG are notarized and stapled.
#   OUTPUT_DIR        where the DMG goes, defaults to .build/dmg.
#
# Prints the path of the DMG as its last line.
set -euo pipefail

version="${1:?usage: build-dmg.sh <version> [build-number]}"
build="${2:-1}"

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${OUTPUT_DIR:-$root/.build/dmg}"
work="$(mktemp -d "${TMPDIR:-/tmp}/memoir-dmg.XXXXXX")"
trap 'rm -rf "$work"' EXIT
archive="$work/Memoir.xcarchive"
dmg="$out/Memoir-$version.dmg"

# Check before archiving, which takes a few minutes.
if ! command -v uvx >/dev/null; then
  echo "error: uv is missing. Install it with: brew install uv" >&2
  exit 1
fi

signed=false
[[ -n "${SIGNING_IDENTITY:-}" ]] && signed=true
notarize=false
$signed && [[ -n "${NOTARY_KEY_PATH:-}" ]] && notarize=true

if $signed; then
  team_id="${DEVELOPMENT_TEAM:?DEVELOPMENT_TEAM must be set when SIGNING_IDENTITY is}"
  signing=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"
    DEVELOPMENT_TEAM="$team_id"
    OTHER_CODE_SIGN_FLAGS=--timestamp
  )
else
  echo "warning: SIGNING_IDENTITY is not set, signing ad-hoc. Gatekeeper will block this build on first launch." >&2
  # Spelled out so a developer's Config/Local.xcconfig can't switch it back to their team.
  signing=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
fi

echo "Archiving Memoir $version ($build)..." >&2
# Own DerivedData so this never invalidates the Debug build in Xcode's.
xcodebuild archive \
  -project "$root/Memoir.xcodeproj" \
  -scheme Memoir \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive" \
  -derivedDataPath "$root/.build/dmg-derived" \
  -quiet \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build" \
  "${signing[@]}" >&2

app="$archive/Products/Applications/Memoir.app"
if $signed; then
  # The export re-signs for distribution and strips anything a Developer ID
  # build must not carry, such as the get-task-allow entitlement.
  cat > "$work/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$SIGNING_IDENTITY</string>
  <key>teamID</key><string>$team_id</string>
</dict>
</plist>
PLIST
  xcodebuild -exportArchive \
    -archivePath "$archive" \
    -exportPath "$work/export" \
    -exportOptionsPlist "$work/ExportOptions.plist" >&2
  app="$work/export/Memoir.app"
fi
codesign --verify --deep --strict "$app" >&2

# The settings for AI assistants point MCP clients at this path, so a bundle
# without it builds and launches fine but breaks every assistant setup.
bridge="$app/Contents/MacOS/memoir-mcp"
if [[ ! -x "$bridge" ]]; then
  echo "error: Memoir.app doesn't embed memoir-mcp in Contents/MacOS" >&2
  exit 1
fi
codesign --verify --strict "$bridge" >&2

if $notarize; then
  # Stapling the app itself, not only the DMG, lets it pass Gatekeeper offline
  # once it has been copied out of the disk image.
  echo "Notarizing the app..." >&2
  ditto -c -k --keepParent "$app" "$work/Memoir.zip"
  "$root/scripts/notarize.sh" "$work/Memoir.zip" >&2
  xcrun stapler staple "$app" >&2
fi

echo "Building the DMG..." >&2
mkdir -p "$out"
rm -f "$dmg"
# dmgbuild writes the window layout into the .DS_Store itself. Tools that
# script Finder for it tend to hang on CI. Pinned so an update can't move things.
uvx --from dmgbuild==2.0.0 dmgbuild \
  -s "$root/scripts/dmg/settings.py" \
  -D app="$app" \
  -D background="$root/scripts/dmg/background.tiff" \
  Memoir "$dmg" >&2

if $signed; then
  codesign --sign "$SIGNING_IDENTITY" --timestamp "$dmg" >&2
fi
if $notarize; then
  echo "Notarizing the DMG..." >&2
  "$root/scripts/notarize.sh" "$dmg" >&2
  xcrun stapler staple "$dmg" >&2
  spctl --assess --type open --context context:primary-signature --verbose "$dmg" >&2
fi

echo "$dmg"
