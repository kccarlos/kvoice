#!/bin/sh
# Check that a built App Store edition (ADR-026) carries the sandbox and
# exactly the entitlements ADR-026 justifies — the counterpart of
# check_release_signature.sh, which requires the opposite (no sandbox) of the
# Developer ID edition.
#
#   - the seal verifies (`codesign --verify --deep --strict`);
#   - the entitlements are exactly app-sandbox, device.audio-input,
#     network.client, files.user-selected.read-write and
#     files.bookmarks.app-scope, all true; no get-task-allow (plus, when a
#     provisioning profile is embedded, the application- and
#     team-identifier keys signing with it adds);
#   - Info.plist says KvoiceDistributionEdition = appStore.
#
# With --pcc (ADR-027: an archive made with KVOICE_PCC_ENTITLEMENT=1) the
# set must also contain `com.apple.developer.private-cloud-compute` = true,
# and the bundle must embed a provisioning profile (the managed entitlement
# reaches an app only through one). Without --pcc that key is refused: a
# local build signed with it and no profile is exactly what must not ship.
#
# With --developer-id (the App Store edition signed with a Developer ID for
# a notarized test DMG, the preview workflow) every check above still
# applies, and also what notarization requires: a "Developer ID
# Application" authority, the hardened runtime, a secure timestamp on the
# app and every nested code item, and no embedded provisioning profile
# (none of the five entitlements needs one, and a Developer ID signature
# does not use the store's). --developer-id and --pcc exclude each other:
# the managed entitlement needs a profile.
#
# Without --developer-id the signing authority is not checked: a local
# sandbox build is signed with the local identity; App Store Connect checks
# the archive's own signature.
#
# Usage: check_app_store_signature.sh [--pcc | --developer-id] <path/to/kvoice.app>
set -eu

usage="usage: check_app_store_signature.sh [--pcc | --developer-id] <path/to/kvoice.app>"
require_pcc=false
require_developer_id=false
while [ $# -gt 0 ]; do
    case "$1" in
        --pcc) require_pcc=true; shift ;;
        --developer-id) require_developer_id=true; shift ;;
        -*) echo "check_app_store_signature: unknown option $1; $usage" >&2; exit 2 ;;
        *) break ;;
    esac
done
if [ "$require_pcc" = true ] && [ "$require_developer_id" = true ]; then
    echo "check_app_store_signature: --pcc and --developer-id exclude each other (the Private Cloud Compute entitlement needs a provisioning profile; a Developer ID test build has none)" >&2
    exit 2
fi
app="${1:?$usage}"
[ -d "$app" ] || { echo "check_app_store_signature: no app bundle at $app" >&2; exit 2; }

failures=0
fail() {
    echo "check_app_store_signature: FAIL: $1" >&2
    failures=$((failures + 1))
}

codesign --verify --deep --strict --verbose=2 "$app" || fail "codesign --verify --deep --strict rejects the bundle"

entitlements="$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)"
case "$entitlements" in
    *com.apple.security.get-task-allow*) fail "com.apple.security.get-task-allow is present" ;;
esac
keys="$(printf '%s' "$entitlements" | grep -o '<key>[^<]*</key>' | sed 's/<[^>]*>//g' | sort | tr '\n' ' ')"
# Signing with a provisioning profile (the App Store archive) adds the two
# identity keys the profile grants; they are not in the entitlements file.
# Without an embedded profile they must not appear.
if [ -f "$app/Contents/embedded.provisionprofile" ]; then
    for identity_key in com.apple.application-identifier com.apple.developer.team-identifier; do
        case " $keys" in
            *" $identity_key "*) ;;
            *) fail "signed with a provisioning profile but without $identity_key" ;;
        esac
        keys="$(printf '%s' " $keys" | sed "s/ $identity_key / /; s/^ //")"
    done
fi
if [ "$require_pcc" = true ]; then
    expected="com.apple.developer.private-cloud-compute com.apple.security.app-sandbox com.apple.security.device.audio-input com.apple.security.files.bookmarks.app-scope com.apple.security.files.user-selected.read-write com.apple.security.network.client "
    [ -f "$app/Contents/embedded.provisionprofile" ] \
        || fail "no Contents/embedded.provisionprofile: the managed Private Cloud Compute entitlement needs one (ADR-027)"
else
    expected="com.apple.security.app-sandbox com.apple.security.device.audio-input com.apple.security.files.bookmarks.app-scope com.apple.security.files.user-selected.read-write com.apple.security.network.client "
fi
[ "$keys" = "$expected" ] || fail "entitlements are '${keys}', expected '${expected}'"
case "$entitlements" in
    *"<false/>"*) fail "an entitlement is false" ;;
esac

edition="$(/usr/libexec/PlistBuddy -c 'Print :KvoiceDistributionEdition' "$app/Contents/Info.plist" 2>/dev/null || true)"
[ "$edition" = "appStore" ] || fail "KvoiceDistributionEdition is '${edition}', expected appStore"

if [ "$require_developer_id" = true ]; then
    details="$(codesign -dvv "$app" 2>&1 || true)"
    authority="$(printf '%s\n' "$details" | sed -n 's/^Authority=//p' | head -1)"
    if printf '%s\n' "$details" | grep -q '^Signature=adhoc'; then
        authority="(ad-hoc)"
    fi
    echo "check_app_store_signature: authority: ${authority:-none}"
    case "$authority" in
        "Developer ID Application: "*) ;;
        *) fail "signed by '${authority:-nothing}', not a 'Developer ID Application' identity — notarization would reject it" ;;
    esac
    # `flags=0x10000(runtime)` under the hardened runtime.
    printf '%s\n' "$details" | grep -q '^CodeDirectory .*flags=0x[0-9a-f]*(.*runtime' \
        || fail "the hardened runtime is off (ENABLE_HARDENED_RUNTIME, inherited from Config/Release.xcconfig)"
    [ ! -e "$app/Contents/embedded.provisionprofile" ] \
        || fail "Contents/embedded.provisionprofile is present; a Developer ID build of this edition carries none"
    for code in "$app" "$app"/Contents/Resources/*.bundle "$app"/Contents/MacOS/*.dylib "$app"/Contents/Frameworks/*; do
        [ -e "$code" ] || continue
        codesign -dvv "$code" 2>&1 | grep -q '^Timestamp=' \
            || fail "no secure timestamp on ${code#"$app"/} (build_app.sh AppStore adds --timestamp for a Developer ID; needs the network at sign time)"
    done
fi

if [ "$failures" -gt 0 ]; then
    echo "check_app_store_signature: $failures problem(s) in $app" >&2
    exit 1
fi
if [ "$require_pcc" = true ]; then
    echo "check_app_store_signature: OK — sandboxed, ADR-026 entitlements + Private Cloud Compute, provisioning profile embedded, edition appStore: $app"
elif [ "$require_developer_id" = true ]; then
    echo "check_app_store_signature: OK — sandboxed, ADR-026 entitlements, edition appStore, Developer ID, hardened runtime, timestamped, no profile: $app"
else
    echo "check_app_store_signature: OK — sandboxed, ADR-026 entitlements, edition appStore: $app"
fi
