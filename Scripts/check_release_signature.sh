#!/bin/sh
# Check that a built kvoice.app is signed the way notarization requires
# (the release documentation, "Developer ID and notarization"), before anything is
# uploaded to Apple:
#
#   - the seal verifies (`codesign --verify --deep --strict`);
#   - the main executable runs under the hardened runtime;
#   - the entitlements are exactly `com.apple.security.device.audio-input`
#     — in particular no `com.apple.security.get-task-allow`, which Xcode
#     injects into a `build` unless Config/Release.xcconfig turns it off,
#     and no App Sandbox (ADR-009);
#   - the app and every nested bundle carry a secure timestamp — skipped
#     for an ad-hoc signature, which cannot be timestamped;
#   - Info.plist says KvoiceDistributionEdition = developerID (ADR-026; the
#     App Store edition's check is check_app_store_signature.sh).
#
# Usage: check_release_signature.sh [--developer-id] <path/to/kvoice.app>
#   --developer-id   also require a "Developer ID Application" authority,
#                    the only one notarization accepts.
#
# Exits non-zero with one line per failure.
set -eu

require_developer_id=false
if [ "${1:-}" = "--developer-id" ]; then
    require_developer_id=true
    shift
fi
app="${1:?usage: check_release_signature.sh [--developer-id] <path/to/kvoice.app>}"
[ -d "$app" ] || { echo "check_release_signature: no app bundle at $app" >&2; exit 2; }

failures=0
fail() {
    echo "check_release_signature: FAIL: $1" >&2
    failures=$((failures + 1))
}

codesign --verify --deep --strict --verbose=2 "$app" || fail "codesign --verify --deep --strict rejects the bundle"

details="$(codesign -dvv "$app" 2>&1)"
authority="$(printf '%s\n' "$details" | sed -n 's/^Authority=//p' | head -1)"
if printf '%s\n' "$details" | grep -q '^Signature=adhoc'; then
    authority="(ad-hoc)"
fi
echo "check_release_signature: authority: ${authority:-none}"

if [ "$require_developer_id" = true ]; then
    case "$authority" in
        "Developer ID Application: "*) ;;
        *) fail "signed by '${authority:-nothing}', not a 'Developer ID Application' identity — notarization would reject it (the release documentation)" ;;
    esac
fi

# The CodeDirectory flags line reads `flags=0x10000(runtime)` under the
# hardened runtime.
printf '%s\n' "$details" | grep -q '^CodeDirectory .*flags=0x[0-9a-f]*(.*runtime' \
    || fail "the hardened runtime is off (ENABLE_HARDENED_RUNTIME in Config/Release.xcconfig)"

entitlements="$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)"
case "$entitlements" in
    *com.apple.security.get-task-allow*) fail "com.apple.security.get-task-allow is present (CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO in Config/Release.xcconfig)" ;;
esac
case "$entitlements" in
    *com.apple.security.app-sandbox*) fail "the App Sandbox entitlement is present; ADR-009 keeps the app unsandboxed" ;;
esac
# ADR-027: Apple offers Private Cloud Compute to App Store distribution only;
# the Developer ID edition reports it unavailable and never carries the key.
case "$entitlements" in
    *com.apple.developer.private-cloud-compute*) fail "the Private Cloud Compute entitlement is present; ADR-027 keeps it to the App Store edition" ;;
esac
keys="$(printf '%s' "$entitlements" | grep -o '<key>[^<]*</key>' | sed 's/<[^>]*>//g' | sort | tr '\n' ' ')"
[ "$keys" = "com.apple.security.device.audio-input " ] \
    || fail "entitlements are '${keys}', expected exactly com.apple.security.device.audio-input"

edition="$(/usr/libexec/PlistBuddy -c 'Print :KvoiceDistributionEdition' "$app/Contents/Info.plist" 2>/dev/null || true)"
[ "$edition" = "developerID" ] || fail "KvoiceDistributionEdition is '${edition}', expected developerID (ADR-026)"
package_type="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$app/Contents/Info.plist" 2>/dev/null || true)"
[ "$package_type" = "APPL" ] || fail "CFBundlePackageType is '${package_type}', expected APPL (Gatekeeper rejects the bundle as 'not an app' without it)"

if [ "$authority" != "(ad-hoc)" ]; then
    # The app, then every nested code item: the SwiftPM resource bundles
    # today; dylibs and frameworks if a dependency ever adds one.
    for code in "$app" "$app"/Contents/Resources/*.bundle "$app"/Contents/MacOS/*.dylib "$app"/Contents/Frameworks/*; do
        [ -e "$code" ] || continue
        codesign -dvv "$code" 2>&1 | grep -q '^Timestamp=' \
            || fail "no secure timestamp on ${code#"$app"/} (OTHER_CODE_SIGN_FLAGS = --timestamp; needs the network at sign time)"
    done
fi

if [ "$failures" -gt 0 ]; then
    echo "check_release_signature: $failures problem(s) in $app" >&2
    exit 1
fi
echo "check_release_signature: OK — hardened runtime, timestamped, entitlements = audio-input only, edition developerID: $app"
