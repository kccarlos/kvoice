#!/bin/sh
# Check that the selected Xcode can build kvoice before a CI job spends time
# on it, and say what to change when it cannot (Docs/Build.md).
#
# The app compiles against APIs that exist only in the macOS 27 SDK (Private
# Cloud Compute's PrivateCloudComputeLanguageModel, among others; every use
# is behind `#available`, so the app still runs on macOS 15). An older Xcode
# fails deep inside the build with "cannot find type" errors; this fails
# first, with the reason.
#
# Usage: ci_check_toolchain.sh [minimum-major]   (default 27)
# Honours DEVELOPER_DIR like every other script.
set -eu

minimum="${1:-27}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

fail() {
    # `::error::` is a GitHub Actions annotation; elsewhere it is plain text.
    echo "::error::$1" >&2
    exit 1
}

[ -d "$DEVELOPER_DIR" ] || fail "DEVELOPER_DIR=$DEVELOPER_DIR does not exist. On GitHub-hosted runners Xcode $minimum is on the 'xcode-$minimum' image (runs-on: xcode-$minimum); list what an image has with 'ls /Applications | grep Xcode'."

xcode_version="$(xcodebuild -version | sed -n 's/^Xcode \([0-9.]*\).*/\1/p')"
build_version="$(xcodebuild -version | sed -n 's/^Build version //p')"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
swift_version="$(xcrun swift --version 2>/dev/null | head -1)"
echo "DEVELOPER_DIR: $DEVELOPER_DIR"
echo "Xcode: $xcode_version ($build_version)"
echo "macOS SDK: $sdk_version"
echo "Swift: $swift_version"
echo "Runner OS: $(sw_vers -productVersion) ($(uname -m))"

[ "${xcode_version%%.*}" -ge "$minimum" ] 2>/dev/null \
    || fail "Xcode $xcode_version is too old: kvoice needs Xcode $minimum or later (the macOS $minimum SDK). Point DEVELOPER_DIR at an Xcode $minimum install, or run on a runner that has one."
[ "${sdk_version%%.*}" -ge "$minimum" ] 2>/dev/null \
    || fail "the macOS SDK is $sdk_version: kvoice needs the macOS $minimum SDK, which ships with Xcode $minimum."
[ "$(uname -m)" = "arm64" ] || fail "kvoice builds for Apple Silicon only; this runner is $(uname -m)."
echo "ci_check_toolchain: OK"
