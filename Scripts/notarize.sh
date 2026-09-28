#!/bin/sh
# Notarize and staple a Developer ID-signed kvoice.app or release DMG, then
# check that Gatekeeper accepts it (the release documentation, "Developer ID and
# notarization").
#
# Usage: notarize.sh <path/to/kvoice.app | path/to/KVoice-x.y.z.dmg>
#
# Credentials, in this order:
#   NOTARY_API_KEY_PATH + NOTARY_API_KEY_ID + NOTARY_API_ISSUER_ID
#       an App Store Connect API key (the .p8 file, its key ID, the issuer
#       ID): the release workflow's preferred secrets.
#   APPLE_ID + APPLE_TEAM_ID + APPLE_APP_SPECIFIC_PASSWORD
#       all three set: an Apple ID with an app-specific password.
#   KVOICE_NOTARY_PROFILE (default "kvoice-notary")
#       a keychain profile stored once with
#       `xcrun notarytool store-credentials kvoice-notary ...`.
#
# A .app is zipped with ditto (notarytool takes a zip, dmg or pkg, not a
# bare bundle), submitted, and the ticket is stapled to the .app itself so
# the copy inside the DMG works offline. A .dmg is submitted and stapled as
# is. The script refuses before uploading anything when the signature is
# not a Developer ID one or the credentials are missing — every failure
# names what to do next.
set -eu

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

target="${1:?usage: notarize.sh <path/to/kvoice.app | path/to/KVoice-x.y.z.dmg>}"
target="${target%/}"
script_dir="$(cd "$(dirname "$0")" && pwd)"

die() {
    echo "notarize: $1" >&2
    exit 1
}

[ -e "$target" ] || die "nothing at $target"
case "$target" in
    *.app) kind=app ;;
    *.dmg) kind=dmg ;;
    *) die "expected a .app or a .dmg, got $target" ;;
esac

# 1. The signature. Notarization accepts only a Developer ID Application
#    signature with the hardened runtime and a secure timestamp.
if [ "$kind" = app ]; then
    "$script_dir/check_release_signature.sh" --developer-id "$target" \
        || die "$target is not signed for notarization (above). Build it with ./Scripts/build_app.sh Release once the 'Developer ID Application' certificate is in the keychain (the release documentation, one-time setup)."
else
    details="$(codesign -dvv "$target" 2>&1)" \
        || die "$target has no code signature. Package it with ./Scripts/make_dmg.sh, which signs the DMG with the app's identity."
    authority="$(printf '%s\n' "$details" | sed -n 's/^Authority=//p' | head -1)"
    case "$authority" in
        "Developer ID Application: "*) ;;
        *) die "$target is signed by '${authority:-nothing}', not a 'Developer ID Application' identity. Rebuild the app with the Developer ID and repackage (the release documentation)." ;;
    esac
    printf '%s\n' "$details" | grep -q '^Timestamp=' \
        || die "$target's signature has no secure timestamp; ./Scripts/make_dmg.sh signs with --timestamp (needs the network)."
fi

# 2. The credentials.
if [ -n "${NOTARY_API_KEY_PATH:-}" ]; then
    [ -f "$NOTARY_API_KEY_PATH" ] || die "NOTARY_API_KEY_PATH names no file."
    [ -n "${NOTARY_API_KEY_ID:-}" ] && [ -n "${NOTARY_API_ISSUER_ID:-}" ] \
        || die "NOTARY_API_KEY_PATH needs NOTARY_API_KEY_ID and NOTARY_API_ISSUER_ID too."
    set -- --key "$NOTARY_API_KEY_PATH" --key-id "$NOTARY_API_KEY_ID" --issuer "$NOTARY_API_ISSUER_ID"
    echo "notarize: using the App Store Connect API key credentials"
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]; then
    set -- --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD"
    echo "notarize: using the APPLE_ID / APPLE_TEAM_ID / APPLE_APP_SPECIFIC_PASSWORD credentials"
else
    profile="${KVOICE_NOTARY_PROFILE:-kvoice-notary}"
    # `history` reads the profile from the keychain first and fails at once,
    # offline, when it does not exist.
    if ! probe="$(xcrun notarytool history --keychain-profile "$profile" 2>&1)" \
        || printf '%s' "$probe" | grep -q 'No Keychain password item found'; then
        printf '%s\n' "$probe" >&2
        die "no notarization credentials. Set NOTARY_API_KEY_PATH, NOTARY_API_KEY_ID and
  NOTARY_API_ISSUER_ID (an App Store Connect API key), or all three of APPLE_ID, APPLE_TEAM_ID and
  APPLE_APP_SPECIFIC_PASSWORD, or store a keychain profile once on this Mac (the release
  documentation):
    xcrun notarytool store-credentials $profile --apple-id <apple-id> --team-id <team-id>
  (it prompts for an app-specific password); KVOICE_NOTARY_PROFILE names another profile.
  Tried the keychain profile '$profile'."
    fi
    set -- --keychain-profile "$profile"
    echo "notarize: using the notarytool keychain profile '$profile'"
fi

# 3. Submit and wait. notarytool exits non-zero on "Invalid"; the log says
#    why, so fetch it before failing.
workdir="$(mktemp -d "${TMPDIR:-/tmp}/kvoice-notarize.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT
upload="$target"
if [ "$kind" = app ]; then
    upload="$workdir/$(basename "$target" .app).zip"
    ditto -c -k --keepParent "$target" "$upload"
fi

echo "notarize: submitting $(basename "$upload") — this usually takes a few minutes"
result_file="$workdir/notarytool-result.plist"
status=0
xcrun notarytool submit "$upload" "$@" --wait --output-format plist > "$result_file" || status=$?
submission_id="$(/usr/libexec/PlistBuddy -c 'Print :id' "$result_file" 2>/dev/null || true)"
submission_status="$(/usr/libexec/PlistBuddy -c 'Print :status' "$result_file" 2>/dev/null || true)"
echo "notarize: submission ${submission_id:-?} finished: ${submission_status:-unknown}"
if [ "$status" -ne 0 ] || { [ -n "$submission_status" ] && [ "$submission_status" != "Accepted" ]; }; then
    cat "$result_file" >&2 || true
    if [ -n "$submission_id" ]; then
        echo "notarize: the notary log:" >&2
        xcrun notarytool log "$submission_id" "$@" >&2 || true
    fi
    die "Apple did not accept $target."
fi
if [ -z "$submission_status" ]; then
    # notarytool succeeded but its plist did not parse as expected (its
    # shape is not pinned). Stapling below cannot succeed without an
    # accepted ticket, so it is the real gate; show the raw result.
    echo "notarize: could not read the status from notarytool's output; relying on stapler:" >&2
    cat "$result_file" >&2 || true
fi

# 4. Staple the ticket and check what a user's Mac will check.
xcrun stapler staple "$target"
xcrun stapler validate "$target"
if [ "$kind" = app ]; then
    spctl --assess --type execute -vv "$target"
else
    # A DMG is assessed as a document to open; its own signature is the
    # "primary signature" context.
    spctl --assess --type open --context context:primary-signature -vv "$target"
fi
# Stapling appended the ticket to the DMG, so a checksum sidecar written by
# make_dmg.sh no longer matches; rewrite it.
if [ "$kind" = dmg ] && [ -f "$target.sha256" ]; then
    (cd "$(dirname "$target")" && shasum -a 256 "$(basename "$target")" > "$(basename "$target").sha256")
    echo "notarize: rewrote $target.sha256 for the stapled DMG"
fi
echo "notarize: $target is notarized, stapled and accepted by Gatekeeper on this Mac"
