#!/bin/sh
# Derive the release version from a `v*` tag and print the two build
# settings the release build overrides (the release documentation):
#
#   MARKETING_VERSION   the tag without its leading "v" (v0.1.0 → 0.1.0)
#   CURRENT_PROJECT_VERSION   the Actions run number, so every release build
#                             has a build number that only ever goes up
#   KVOICE_STORE_VERSION      MARKETING_VERSION without a pre-release suffix,
#                             for the App Store build
#
# Usage: release_version.sh <tag> <build-number>
# Prints `KEY=VALUE` lines suitable for `>> "$GITHUB_ENV"`.
set -eu

tag="${1:?usage: release_version.sh <tag> <build-number>}"
build="${2:?usage: release_version.sh <tag> <build-number>}"

case "$tag" in
    v*) version="${tag#v}" ;;
    *) echo "release_version: tag '$tag' does not start with 'v'" >&2; exit 2 ;;
esac

# Semantic version with an optional pre-release suffix (v0.2.0-rc.1). A
# `CFBundleShortVersionString` must be dotted integers for the App Store,
# but this is a direct-download DMG, so a suffix is allowed and marks the
# GitHub Release as a pre-release.
if ! printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'; then
    echo "release_version: '$version' is not MAJOR.MINOR.PATCH[-prerelease]" >&2
    exit 2
fi
if ! printf '%s' "$build" | grep -Eq '^[0-9]+$'; then
    echo "release_version: build number '$build' is not an integer" >&2
    exit 2
fi

prerelease=false
case "$version" in *-*) prerelease=true ;; esac

echo "KVOICE_MARKETING_VERSION=$version"
# The Mac App Store takes dotted integers only: a pre-release tag's App
# Store build (a TestFlight candidate) carries the version without the
# suffix, and its build number tells the candidates apart.
echo "KVOICE_STORE_VERSION=${version%%-*}"
echo "KVOICE_BUILD_NUMBER=$build"
echo "KVOICE_PRERELEASE=$prerelease"
