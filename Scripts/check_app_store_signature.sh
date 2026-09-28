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
# Signing authority is not checked: a local sandbox build is signed with the
# local identity; App Store Connect checks the archive's own signature.
#
# Usage: check_app_store_signature.sh [--pcc] <path/to/kvoice.app>
set -eu

require_pcc=false
if [ "${1:-}" = "--pcc" ]; then
    require_pcc=true
    shift
fi
app="${1:?usage: check_app_store_signature.sh [--pcc] <path/to/kvoice.app>}"
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

if [ "$failures" -gt 0 ]; then
    echo "check_app_store_signature: $failures problem(s) in $app" >&2
    exit 1
fi
if [ "$require_pcc" = true ]; then
    echo "check_app_store_signature: OK — sandboxed, ADR-026 entitlements + Private Cloud Compute, provisioning profile embedded, edition appStore: $app"
else
    echo "check_app_store_signature: OK — sandboxed, ADR-026 entitlements, edition appStore: $app"
fi
