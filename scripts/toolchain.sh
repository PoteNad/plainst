# Sourced by the build scripts to choose working developer tools.

# Use the selected developer tools, falling back to the Command Line Tools when the
# selection cannot run Swift (for example, before Xcode's license has been accepted).
if [ -z "${DEVELOPER_DIR:-}" ] && ! swift -e 'import Foundation' >/dev/null 2>&1 \
  && [ -d /Library/Developer/CommandLineTools ]; then
  DEVELOPER_DIR=/Library/Developer/CommandLineTools
  export DEVELOPER_DIR
  printf '%s\n' 'Using the Command Line Tools because the selected developer tools cannot run Swift.' >&2
fi
if ! swift -e 'import Foundation' >/dev/null 2>&1; then
  printf '%s\n' 'No working Swift toolchain was found. Install the Xcode Command Line Tools, or accept the Xcode license if Xcode is selected.' >&2
  exit 1
fi

SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
if [ "${SDK_VERSION%%.*}" -lt 26 ]; then
  printf 'Plainst requires the macOS 26 SDK or newer to build with the current AppKit appearance (found %s).\n' "$SDK_VERSION" >&2
  exit 1
fi
# Some SwiftPM toolchains record the deployment target (macOS 13) as the SDK, which gives
# windows older AppKit styling. Package.swift passes this version to the linker.
PLAINST_SDK_VERSION="$SDK_VERSION"
export PLAINST_SDK_VERSION
