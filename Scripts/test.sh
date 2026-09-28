#!/bin/sh
set -eu

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
# --disable-keychain: see Scripts/build.sh and Docs/Build.md.
exec swift test --disable-keychain "$@"
