#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Tests use only the fonts bundled with Typst so results match on every Mac.
export PLAINST_NO_SYSTEM_FONTS=1

. scripts/toolchain.sh

cargo test --locked --manifest-path engine/Cargo.toml
# The third-party notices must list every crate the engine links.
swift scripts/generate-notices.swift --check
PLAINST_CHECKS=1 ./scripts/build.sh
# Command Line Tools installs don't always find Swift Testing's macros on their own.
PLUGINS="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
if [ -d "$PLUGINS" ]; then
  swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS"
else
  swift test
fi

APP="build/Plainst.app/Contents/MacOS/Plainst"
IGNORE_STATE="-ApplePersistenceIgnoreState YES"

# shellcheck disable=SC2086
PLAINST_LAUNCH_CHECK=1 "$APP" $IGNORE_STATE
# shellcheck disable=SC2086
# The random edits compare against a plain model, so typing assistance stays off here.
# shellcheck disable=SC2086
PLAINST_EDIT_CHECK=1 "$APP" $IGNORE_STATE -autoPair NO -completions NO
# shellcheck disable=SC2086
PLAINST_INPUT_CHECK=1 "$APP" $IGNORE_STATE

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
printf '= Round trip\r\n\r\nCaf\303\251 *bold* _it_ $x^2$ \344\270\255\346\226\207 -- ok\r\n\r\n$ a/b $\r\n\r\n- item\r\n  - nested\r\n+ one\r\n/ Term: desc\r\n#set text(lang: "en")\r\n// note\r\n```\r\ncode\r\n```\r\n' >"$ROOT/crlf.typ"
# shellcheck disable=SC2086
PLAINST_ROUNDTRIP_CHECK="$ROOT/crlf.typ" "$APP" $IGNORE_STATE
printf '\357\273\277= A byte order mark and no final newline $x$ *unclosed' >"$ROOT/bom.typ"
# shellcheck disable=SC2086
PLAINST_ROUNDTRIP_CHECK="$ROOT/bom.typ" "$APP" $IGNORE_STATE
printf '= Mixed\r\nfirst\nsecond\rthird' >"$ROOT/mixed.typ"
# shellcheck disable=SC2086
PLAINST_ROUNDTRIP_CHECK="$ROOT/mixed.typ" "$APP" $IGNORE_STATE
# shellcheck disable=SC2086
PLAINST_OPEN="$ROOT/crlf.typ" PLAINST_EXPORT_CHECK="$ROOT/out.pdf" "$APP" $IGNORE_STATE
./scripts/build.sh
printf 'All checks passed.\n'
