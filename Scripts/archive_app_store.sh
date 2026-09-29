#!/bin/sh
# Archive the sandboxed Mac App Store edition (ADR-026), export the signed
# package for App Store Connect, and optionally upload it (the release
# documentation, "Mac App Store edition"). A maintainer or the release
# workflow runs this once an "Apple Distribution" certificate exists and the
# App Store Connect app record is created.
#
# Usage: Scripts/archive_app_store.sh [--upload] [output-directory]
#   default output: .build/app-store/
#   --upload  after exporting, upload the .pkg to App Store Connect with
#             `xcrun altool --upload-package` and the API key below. The
#             build then appears in TestFlight; nothing is submitted for
#             review. Without --upload nothing leaves this Mac.
#
# The team: KVOICE_APP_STORE_TEAM, else APPLE_TEAM_ID, else APPLE_TEAM_ID
# from the untracked file ~/.config/kvoice/signing.env (KVOICE_SIGNING_ENV
# names another). Nothing in the repository names a team, so a fork signs
# with its own.
#
# Signing, one of:
#   manual (KVOICE_APP_STORE_PROFILE=<path to a .provisionprofile>): the
#       release workflow's mode. The "Mac App Store Connect" provisioning
#       profile for the app's bundle identifier is installed for Xcode, the
#       archive is signed with "Apple Distribution" and that profile, and the
#       export re-signs with "Apple Distribution" and packages with "Mac
#       Installer Distribution". Both identities must be in the keychain
#       (Scripts/ci_import_signing_identity.sh on CI). Nothing is created in
#       the developer account.
#   automatic (no profile given): Xcode's automatic signing with
#       -allowProvisioningUpdates, which may create or download certificates
#       and profiles. It needs the account signed in to Xcode (Settings ›
#       Accounts) or an App Store Connect API key with the Admin role.
#
# App Store Connect API key (the upload, and automatic signing without a
# signed-in account): KVOICE_ASC_KEY_PATH (the AuthKey_<id>.p8 file),
# KVOICE_ASC_KEY_ID, KVOICE_ASC_ISSUER_ID.
#
# Private Cloud Compute (ADR-027): with KVOICE_PCC_ENTITLEMENT=1 the archive
# signs with Apps/KvoiceApp/Kvoice-AppStore-PCC.entitlements, which adds the
# managed `com.apple.developer.private-cloud-compute` entitlement. Only once
# Apple has assigned that capability to the team and it is enabled on the
# App ID (and, for manual signing, the profile was regenerated after that);
# before, signing refuses the entitlement and the archive fails. Without the
# flag the build is exactly ADR-026's, and the app reports Private Cloud
# Compute as unavailable ("not signed for it").
set -eu
cd "$(dirname "$0")/.."

upload=false
if [ "${1:-}" = "--upload" ]; then
    upload=true
    shift
fi

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

signing_env="${KVOICE_SIGNING_ENV:-$HOME/.config/kvoice/signing.env}"
if [ -z "${KVOICE_APP_STORE_TEAM:-}${APPLE_TEAM_ID:-}" ] && [ -f "$signing_env" ]; then
    # shellcheck disable=SC1090 # a developer's own untracked file.
    . "$signing_env"
fi
team="${KVOICE_APP_STORE_TEAM:-${APPLE_TEAM_ID:-}}"
if ! printf '%s' "$team" | grep -Eq '^[A-Z0-9]{10}$'; then
    echo "archive_app_store: no Apple team ID. Set APPLE_TEAM_ID (on CI: the repository variable of that name), or put APPLE_TEAM_ID=<your 10-character team ID> in $signing_env" >&2
    exit 2
fi

output="${1:-.build/app-store}"
archive="$output/kvoice.xcarchive"
export_dir="$output/export"
options="$output/ExportOptions.plist"
derived_data_path="${KVOICE_DERIVED_DATA_PATH:-.build/xcode-derived}"
bundle_id="io.github.kccarlos.kvoice"

auth_flags=""
if [ -n "${KVOICE_ASC_KEY_PATH:-}" ]; then
    [ -f "$KVOICE_ASC_KEY_PATH" ] || { echo "archive_app_store: KVOICE_ASC_KEY_PATH names no file" >&2; exit 2; }
    # The path is passed through an unquoted word list below.
    case "$KVOICE_ASC_KEY_PATH$KVOICE_ASC_KEY_ID$KVOICE_ASC_ISSUER_ID" in
        *[[:space:]]*) echo "archive_app_store: the API key path, ID and issuer must not contain whitespace" >&2; exit 2 ;;
    esac
    auth_flags="-authenticationKeyPath $KVOICE_ASC_KEY_PATH -authenticationKeyID ${KVOICE_ASC_KEY_ID:?KVOICE_ASC_KEY_ID is required with KVOICE_ASC_KEY_PATH} -authenticationKeyIssuerID ${KVOICE_ASC_ISSUER_ID:?KVOICE_ASC_ISSUER_ID is required with KVOICE_ASC_KEY_PATH}"
fi
if [ "$upload" = true ] && [ -z "$auth_flags" ]; then
    echo "archive_app_store: --upload needs an App Store Connect API key: KVOICE_ASC_KEY_PATH, KVOICE_ASC_KEY_ID, KVOICE_ASC_ISSUER_ID" >&2
    exit 2
fi

mkdir -p "$output"
# Generated from the template so the team is a variable, not a committed
# constant.
sed "s/__TEAM_ID__/$team/" Config/ExportOptions-AppStore.plist > "$options"

signing_settings="CODE_SIGN_STYLE=Automatic"
provisioning_flags="-allowProvisioningUpdates"
profile="${KVOICE_APP_STORE_PROFILE:-}"
if [ -n "$profile" ]; then
    [ -f "$profile" ] || { echo "archive_app_store: KVOICE_APP_STORE_PROFILE names no file" >&2; exit 2; }
    decoded="$output/profile.plist"
    security cms -D -i "$profile" > "$decoded"
    profile_uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$decoded")"
    profile_name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$decoded")"
    profile_team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$decoded")"
    profile_app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$decoded")"
    rm -f "$decoded"
    [ "$profile_team" = "$team" ] \
        || { echo "archive_app_store: the profile belongs to team $profile_team, not $team" >&2; exit 2; }
    [ "$profile_app_id" = "$team.$bundle_id" ] \
        || { echo "archive_app_store: the profile is for $profile_app_id, not $team.$bundle_id" >&2; exit 2; }
    # Xcode 16 and later read profiles from the first directory; older
    # releases from the second.
    for directory in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
        "$HOME/Library/MobileDevice/Provisioning Profiles"; do
        mkdir -p "$directory"
        cp "$profile" "$directory/$profile_uuid.provisionprofile"
    done
    echo "archive_app_store: manual signing with the profile '$profile_name' ($profile_uuid)"
    # The profile reaches the app target only, through
    # Config/AppStore.xcconfig: a PROVISIONING_PROFILE_SPECIFIER on the
    # command line would also apply to the SwiftPM resource bundles, which
    # cannot take one.
    signing_settings="CODE_SIGN_STYLE=Manual"
    provisioning_flags=""
    # Apple issues the installer certificate under either name: the older
    # "3rd Party Mac Developer Installer: …" or "Mac Installer Distribution:
    # …". exportArchive matches the name literally, so use whichever this
    # keychain holds (the v0.1.0 run failed on the literal newer name).
    installer_identity="$(security find-identity -v -p basic 2>/dev/null \
        | grep -oE '"(3rd Party Mac Developer Installer|Mac Installer Distribution): ' \
        | head -n 1 | sed -e 's/^"//' -e 's/: $//')"
    [ -n "$installer_identity" ] \
        || { echo "archive_app_store: no Mac Installer Distribution / 3rd Party Mac Developer Installer identity in the keychain" >&2; exit 2; }
    echo "archive_app_store: installer identity '$installer_identity'"
    /usr/libexec/PlistBuddy \
        -c 'Set :signingStyle manual' \
        -c 'Add :signingCertificate string Apple Distribution' \
        -c "Add :installerSigningCertificate string $installer_identity" \
        -c 'Add :provisioningProfiles dict' \
        -c "Add :provisioningProfiles:$bundle_id string $profile_uuid" \
        "$options"
fi
plutil -lint "$options" >/dev/null

version_overrides=""
if [ -n "${KVOICE_MARKETING_VERSION:-}" ]; then
    version_overrides="MARKETING_VERSION=$KVOICE_MARKETING_VERSION"
fi
if [ -n "${KVOICE_BUILD_NUMBER:-}" ]; then
    version_overrides="$version_overrides CURRENT_PROJECT_VERSION=$KVOICE_BUILD_NUMBER"
fi

entitlement_override=""
if [ "${KVOICE_PCC_ENTITLEMENT:-0}" = "1" ]; then
    entitlement_override="CODE_SIGN_ENTITLEMENTS=Apps/KvoiceApp/Kvoice-AppStore-PCC.entitlements"
    echo "archive_app_store: signing with the Private Cloud Compute entitlement (ADR-027)"
fi

if [ "$signing_settings" = "CODE_SIGN_STYLE=Manual" ]; then
    # shellcheck disable=SC2086 # deliberate word lists.
    xcodebuild \
        -project Kvoice.xcodeproj \
        -scheme kvoice \
        -configuration AppStore \
        -sdk macosx \
        -derivedDataPath "$derived_data_path" \
        -archivePath "$archive" \
        CODE_SIGNING_ALLOWED=YES \
        CODE_SIGNING_REQUIRED=YES \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="Apple Distribution" \
        KVOICE_APP_STORE_PROFILE_SPECIFIER="$profile_name" \
        DEVELOPMENT_TEAM="$team" \
        $version_overrides \
        $entitlement_override \
        archive
else
    # shellcheck disable=SC2086 # deliberate word lists.
    xcodebuild \
        -project Kvoice.xcodeproj \
        -scheme kvoice \
        -configuration AppStore \
        -sdk macosx \
        -derivedDataPath "$derived_data_path" \
        -archivePath "$archive" \
        $provisioning_flags $auth_flags \
        CODE_SIGNING_ALLOWED=YES \
        CODE_SIGNING_REQUIRED=YES \
        CODE_SIGN_STYLE=Automatic \
        DEVELOPMENT_TEAM="$team" \
        $version_overrides \
        $entitlement_override \
        archive
fi

# The archived app, before anything is exported or uploaded: the sandbox,
# exactly the ADR-026 entitlements (plus Private Cloud Compute when asked
# for, which also needs the embedded profile), edition appStore.
check_flags=""
if [ "${KVOICE_PCC_ENTITLEMENT:-0}" = "1" ]; then
    check_flags="--pcc"
fi
# shellcheck disable=SC2086
./Scripts/check_app_store_signature.sh $check_flags "$archive/Products/Applications/kvoice.app"

# shellcheck disable=SC2086
xcodebuild \
    -exportArchive \
    -archivePath "$archive" \
    -exportPath "$export_dir" \
    -exportOptionsPlist "$options" \
    $provisioning_flags $auth_flags

package="$(find "$export_dir" -maxdepth 1 -name '*.pkg' | head -1)"
[ -n "$package" ] || { echo "archive_app_store: the export produced no .pkg in $export_dir" >&2; exit 1; }
echo "archive_app_store: exported $package"

if [ "$upload" = false ]; then
    echo "archive_app_store: not uploaded (pass --upload to send it to App Store Connect)"
    exit 0
fi

# altool looks for the key by id; --p8-file-path points it at the file
# instead of ~/.appstoreconnect/private_keys.
xcrun altool --upload-package "$package" \
    --api-key "$KVOICE_ASC_KEY_ID" \
    --api-issuer "$KVOICE_ASC_ISSUER_ID" \
    --p8-file-path "$KVOICE_ASC_KEY_PATH" \
    --output-format normal
echo "archive_app_store: uploaded to App Store Connect; the build appears in TestFlight once processed"
