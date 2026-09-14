#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

if [ "$#" -ne 1 ]; then
  printf 'Usage: %s VERSION\n' "$0" >&2
  exit 64
fi
VERSION="$1"
. scripts/toolchain.sh
DIST="$PWD/dist"
STAGE="$DIST/staging"
APP="$STAGE/Plainst.app"
ARCHIVE_NAME="Plainst-$VERSION-macOS.zip"
DISK_IMAGE_NAME="Plainst-$VERSION-macOS.dmg"
ARCHIVE="$DIST/$ARCHIVE_NAME"
DISK_IMAGE="$DIST/$DISK_IMAGE_NAME"

rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for ARCH in arm64 x86_64; do
  case "$ARCH" in
  arm64) TARGET=aarch64-apple-darwin ;;
  x86_64) TARGET=x86_64-apple-darwin ;;
  esac
  rustup target add "$TARGET" >/dev/null
  MACOSX_DEPLOYMENT_TARGET=13.0 cargo build --release --locked \
    --manifest-path engine/Cargo.toml --target "$TARGET"
  PLAINST_ENGINE_LIB="$PWD/engine/target/$TARGET/release" \
    swift build -c release --arch "$ARCH" --scratch-path ".build-release-$ARCH"
done
lipo -create \
  .build-release-arm64/release/Plainst \
  .build-release-x86_64/release/Plainst \
  -output "$APP/Contents/MacOS/Plainst"
BUILT_SDK="$(xcrun vtool -show-build "$APP/Contents/MacOS/Plainst" | awk '$1 == "sdk" { print $2; exit }')"
BUILT_SDK_MAJOR="${BUILT_SDK%%.*}"
if [ "$BUILT_SDK_MAJOR" -lt 26 ]; then
  printf 'The release executable was linked against macOS SDK %s.\n' "$BUILT_SDK" >&2
  exit 1
fi

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
(cd "$DIST" && shasum -a 256 "$ARCHIVE_NAME" >"$ARCHIVE_NAME.sha256")
hdiutil create -volname Plainst -srcfolder "$STAGE" -ov -format UDZO "$DISK_IMAGE"
cp "$DISK_IMAGE" "$DIST/Plainst-macOS.dmg"
(cd "$DIST" && shasum -a 256 "$DISK_IMAGE_NAME" >"$DISK_IMAGE_NAME.sha256")
printf 'Created %s and %s with macOS SDK %s\n' "$ARCHIVE" "$DISK_IMAGE" "$BUILT_SDK"
