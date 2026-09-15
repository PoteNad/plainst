#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
. scripts/toolchain.sh
# Only the Rust build needs this; Swift reads the target from Package.swift.
MACOSX_DEPLOYMENT_TARGET=13.0 cargo build --release --locked --manifest-path engine/Cargo.toml
swift build -c release "$@"
BUILT_SDK="$(xcrun vtool -show-build .build/release/Plainst | awk '$1 == "sdk" { print $2; exit }')"
BUILT_SDK_MAJOR="${BUILT_SDK%%.*}"
if [ "$BUILT_SDK_MAJOR" -lt 26 ]; then
  printf 'The Plainst executable was linked against macOS SDK %s. Clean .build and rebuild with the selected SDK.\n' "$BUILT_SDK" >&2
  exit 1
fi
APP="$PWD/build/Plainst.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Plainst "$APP/Contents/MacOS/Plainst"
# The Liquid Glass icon for macOS 26 and later; Plainst.icns covers earlier versions.
if ! xcrun actool Assets/Plainst.icon \
  --compile "$APP/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 13.0 \
  --app-icon Plainst \
  --output-partial-info-plist "$PWD/build/Plainst-icon-info.plist" >/dev/null; then
  rm -f "$APP/Contents/Resources/Assets.car"
fi
cp Assets/Plainst.icns "$APP/Contents/Resources/Plainst.icns"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
if [ -n "${PLAINST_VERSION:-}" ]; then
  plutil -replace CFBundleShortVersionString -string "$PLAINST_VERSION" "$APP/Contents/Info.plist"
fi
codesign --force --sign - "$APP"
printf 'Built %s with macOS SDK %s\n' "$APP" "$BUILT_SDK"
