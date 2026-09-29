#!/bin/sh
# Package a built kvoice.app as the release DMG (the release documentation).
#
# The image holds the app, THIRD_PARTY_NOTICES.md (the product decision:
# the notices ship inside the disk image, not only in the repo) and an
# /Applications shortcut. It is built with the system's hdiutil so the
# release job needs no extra tooling, then signed with the same identity as
# the app when one is given, and a SHA-256 sidecar is written for the
# release notes.
#
# Usage: make_dmg.sh <configuration> <version> [output-dir]
#   KVOICE_CODE_SIGN_IDENTITY  optional; the DMG's signing identity. Unset:
#                              the app's own signing authority. "-": unsigned.
#   KVOICE_DMG_VOLUME_NAME     optional; the mounted volume's name. Unset:
#                              "KVoice <version>". The preview workflow names
#                              its test builds with it.
# The image is <output-dir>/KVoice-<version>.dmg: <version> may carry a
# suffix (the preview workflow's "0.1.0-preview-<sha>-DeveloperID").
set -eu
cd "$(dirname "$0")/.."

configuration="${1:?usage: make_dmg.sh <configuration> <version> [output-dir]}"
version="${2:?usage: make_dmg.sh <configuration> <version> [output-dir]}"
output_dir="${3:-.build/release}"
derived_data_path="${KVOICE_DERIVED_DATA_PATH:-.build/xcode-derived}"
app="$derived_data_path/Build/Products/$configuration/kvoice.app"

[ -d "$app" ] || { echo "make_dmg: no app at $app — run Scripts/build_app.sh $configuration first" >&2; exit 2; }
[ -f THIRD_PARTY_NOTICES.md ] || { echo "make_dmg: THIRD_PARTY_NOTICES.md is missing" >&2; exit 2; }

# The signature is checked before packaging so a broken seal fails here,
# not on the user's Mac (the signing documentation).
codesign --verify --deep --strict --verbose=2 "$app"

mkdir -p "$output_dir"
staging="$(mktemp -d "${TMPDIR:-/tmp}/kvoice-dmg.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

# ditto, never cp -R: cp drops extended attributes and can break the seal.
# The bundle keeps its lowercase file name: renaming it in the image would
# make a release install (/Applications/KVoice.app) and a development
# install (~/Applications/kvoice.app) look like two different apps to the
# user and to every script that knows the path. Finder shows the display
# name "KVoice" from Info.plist either way.
ditto "$app" "$staging/kvoice.app"
cp THIRD_PARTY_NOTICES.md "$staging/Third-Party Notices.md"
ln -s /Applications "$staging/Applications"

dmg="$output_dir/KVoice-$version.dmg"
rm -f "$dmg"
# hdiutil fails now and then with "Resource busy" on CI runners (a
# background scanner holding the new image; it failed the v0.1.2 release
# once). Retry a few times with a pause before giving up.
attempt=1
until hdiutil create \
    -volname "${KVOICE_DMG_VOLUME_NAME:-KVoice $version}" \
    -srcfolder "$staging" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$dmg" >/dev/null; do
    if [ "$attempt" -ge 4 ]; then
        echo "make_dmg: hdiutil create failed $attempt times" >&2
        exit 1
    fi
    echo "make_dmg: hdiutil create failed (attempt $attempt); retrying" >&2
    attempt=$((attempt + 1))
    rm -f "$dmg"
    sleep $((attempt * 5))
done

# The DMG is signed with the app's identity: KVOICE_CODE_SIGN_IDENTITY when
# the caller names one (the workflows), otherwise the leaf authority of the
# app's own signature, so a local `build_app.sh Release` followed by this
# script signs both with the same certificate. An ad-hoc app leaves the DMG
# unsigned. The secure timestamp is what notarization wants on the DMG's
# signature; it needs the network, like the app's (Config/Release.xcconfig).
identity="${KVOICE_CODE_SIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
    identity="$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
fi
if [ -n "$identity" ] && [ "$identity" != "-" ]; then
    echo "make_dmg: signing the DMG with '$identity'"
    codesign --sign "$identity" --timestamp "$dmg"
    codesign --verify --verbose=2 "$dmg"
else
    echo "make_dmg: the app is signed ad-hoc; the DMG is left unsigned"
fi

(cd "$output_dir" && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
echo "make_dmg: $dmg"
cat "$dmg.sha256"
