#!/bin/bash
# Builds Memoir in Release and installs it to /Applications. Run it again to
# update. Builds the working tree as-is, uncommitted changes included, so use a
# clean worktree on main or a tag if you want a clean install.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dest="/Applications/Memoir.app"
# Own DerivedData so this doesn't trash the Debug build Xcode is using.
derived="$root/.build/install"
built="$derived/Build/Products/Release/Memoir.app"

if [[ -n "$(git -C "$root" status --porcelain)" ]]; then
  echo "note: building with uncommitted changes from $(git -C "$root" rev-parse --abbrev-ref HEAD)"
fi

# Build before quitting so the installed copy keeps running if the build fails.
echo "Building Release..."
xcodebuild \
  -project "$root/Memoir.xcodeproj" \
  -scheme Memoir \
  -configuration Release \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$derived" \
  -quiet \
  build

BUNDLE_ID="$(defaults read "$built/Contents/Info" CFBundleIdentifier)"

# Other copies (Debug build, another checkout) share the bundle id, so match
# on the path to only quit the one in /Applications.
quit_installed() {
  osascript -l JavaScript - "$BUNDLE_ID" "$dest" <<'JS'
ObjC.import('AppKit');
function run(argv) {
  const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(argv[0]);
  let pids = [];
  for (let i = 0; i < apps.count; i++) {
    const app = apps.objectAtIndex(i);
    if (app.bundleURL.path.js === argv[1]) {
      app.terminate;
      pids.push(app.processIdentifier);
    }
  }
  return pids.join(' ');
}
JS
}

# Quitting ends a running recording (Memoir saves it first, without asking), so check first.
if pgrep -qf "^$dest/Contents/MacOS/Memoir"; then
  read -r -p "Memoir is running and will be restarted. Nothing recording? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

pids="$(quit_installed)"
if [[ -n "$pids" ]]; then
  echo "Quitting the installed Memoir..."
  for _ in $(seq 60); do
    alive=false
    for pid in $pids; do
      kill -0 "$pid" 2>/dev/null && alive=true
    done
    $alive || break
    sleep 0.5
  done
  if $alive; then
    echo "error: Memoir is still running. Nothing was installed." >&2
    exit 1
  fi
fi

# Copy to a temp name and swap, so a failed copy can't leave a broken app
# behind. Copying over the old bundle would also leave stale files in it.
staging="$(dirname "$dest")/.Memoir.app.installing"
rm -rf "$staging"
ditto "$built" "$staging"
rm -rf "$dest"
mv "$staging" "$dest"

version="$(defaults read "$dest/Contents/Info" CFBundleShortVersionString) ($(git -C "$root" rev-parse --short HEAD))"
echo "Installed Memoir $version to $dest"

if [[ -n "$pids" ]]; then
  open "$dest"
fi
