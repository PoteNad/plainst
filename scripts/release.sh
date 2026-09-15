#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

if [ "$#" -ne 1 ]; then
  printf 'Usage: %s VERSION\n' "$0" >&2
  exit 64
fi
VERSION="$1"
DIST="$PWD/dist"
STAGE="$DIST/staging"
APP="$STAGE/Plainst.app"
ARCHIVE_NAME="Plainst-$VERSION-macOS.zip"
DISK_IMAGE_NAME="Plainst-$VERSION-macOS.dmg"
ARCHIVE="$DIST/$ARCHIVE_NAME"
DISK_IMAGE="$DIST/$DISK_IMAGE_NAME"

# Checks the SDK and sets PLAINST_SDK_VERSION for Package.swift.
. scripts/toolchain.sh

rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Build the Typst engine and the app for each architecture, then combine them.
for ARCH in arm64 x86_64; do
  case "$ARCH" in
    arm64) TRIPLE=aarch64-apple-darwin ;;
    x86_64) TRIPLE=x86_64-apple-darwin ;;
  esac
  if command -v rustup >/dev/null 2>&1; then
    rustup target add "$TRIPLE"
  fi
  MACOSX_DEPLOYMENT_TARGET=13.0 cargo build --release --locked \
    --manifest-path engine/Cargo.toml --target "$TRIPLE"
  PLAINST_ENGINE_LIB="$PWD/engine/target/$TRIPLE/release" \
    swift build -c release --arch "$ARCH" --scratch-path ".build-release-$ARCH" --product Plainst
done
lipo -create \
  .build-release-arm64/release/Plainst \
  .build-release-x86_64/release/Plainst \
  -output "$APP/Contents/MacOS/Plainst"
for ARCH in arm64 x86_64; do
  BUILT_SDK="$(xcrun vtool -arch "$ARCH" -show-build "$APP/Contents/MacOS/Plainst" | awk '$1 == "sdk" { print $2; exit }')"
  if [ "${BUILT_SDK%%.*}" -lt 26 ]; then
    printf 'The %s executable was linked against macOS SDK %s.\n' "$ARCH" "$BUILT_SDK" >&2
    exit 1
  fi
done
printf 'Linked against macOS SDK %s\n' "$PLAINST_SDK_VERSION"

xcrun actool Assets/Plainst.icon \
  --compile "$APP/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 13.0 \
  --app-icon Plainst \
  --output-partial-info-plist "$DIST/Plainst-icon-info.plist" >/dev/null
cp Assets/Plainst.icns "$APP/Contents/Resources/Plainst.icns"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "${GITHUB_RUN_NUMBER:-1}" "$APP/Contents/Info.plist"

codesign --force --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

rm -f "$ARCHIVE" "$DISK_IMAGE" "$DIST/Plainst-macOS.zip" "$DIST/Plainst-macOS.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
cp "$ARCHIVE" "$DIST/Plainst-macOS.zip"
(cd "$DIST" && shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256")
# hdiutil can size the image too small for a large app, so give it room explicitly.
STAGE_MB="$(du -sm "$STAGE" | cut -f1)"
hdiutil create -volname Plainst -srcfolder "$STAGE" -size "$((STAGE_MB + STAGE_MB / 4 + 20))m" \
  -ov -format UDZO "$DISK_IMAGE"
cp "$DISK_IMAGE" "$DIST/Plainst-macOS.dmg"
(cd "$DIST" && shasum -a 256 "$DISK_IMAGE_NAME" > "$DISK_IMAGE_NAME.sha256")
printf 'Created %s and %s\n' "$ARCHIVE" "$DISK_IMAGE"
