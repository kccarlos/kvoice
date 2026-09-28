#!/bin/sh
set -eu

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
# --disable-keychain: every kvoice dependency is public. Without it SwiftPM
# looks up a github.com credential in the login keychain before downloading
# FluidAudio's binary artifact (ADR-019), and when the keychain holds one
# from another tool that read blocks on a securityd "allow access" dialog
# with no output — the build looks hung. See Docs/Build.md.
exec swift build --disable-keychain "$@"
