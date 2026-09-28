#!/bin/sh
set -eu

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
# Conventional Commits gate (CONTRIBUTING.md). Versioned hooks, so every
# clone gets the same commit-msg check.
git config core.hooksPath .githooks
swift package resolve "$@"
