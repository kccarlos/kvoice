#!/bin/sh
set -eu

configuration="${1:-Debug}"
case "$configuration" in
    Debug|Release|TestHost|Bench|AppStore) ;;
    *) echo "Unsupported configuration: $configuration" >&2; exit 2 ;;
esac

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
derived_data_path="${KVOICE_DERIVED_DATA_PATH:-.build/xcode-derived}"

# Ad-hoc "Sign to Run Locally" by default. CODE_SIGNING_ALLOWED=NO produces a
# bundle with no _CodeSignature, which `codesign --verify` rejects; macOS TCC
# then refuses to attach an Accessibility grant, so the System Settings
# checkbox appears enabled while AXIsProcessTrusted() keeps returning false.
# Ad-hoc signing needs no certificate, so this also works on CI.
# Ad-hoc has one drawback: its cdhash changes every build, so macOS treats each
# build as a new binary and invalidates Accessibility grants. Signing with a
# stable identity keeps the designated requirement constant and the grant
# survives rebuilds, so prefer a local signing identity when one is installed.
# Override with a real identity via KVOICE_CODE_SIGN_IDENTITY when publishing.
#
# A Release build prefers an Apple "Developer ID Application" identity when
# one is in the keychain: that is the only signature notarization accepts
# (the release documentation). KVOICE_DEVELOPER_ID_TEAM, else APPLE_TEAM_ID,
# narrows the choice to one team's identity when the keychain holds several;
# unset, the first valid Developer ID Application identity is used. No team
# is committed, so a fork signs with its own. Every other
# configuration keeps the local identity, because switching Debug to the
# Developer ID would change the designated requirement and drop the
# developer's Accessibility and Microphone grants on their own install.
#
# AppStore (ADR-026) is the sandboxed Mac App Store edition built for a local
# sandbox test: it signs with the local identity like Debug. The signature
# App Store Connect needs ("Apple Distribution", automatic signing, a
# provisioning profile) is made by Scripts/archive_app_store.sh, never here.
# Its bundle identifier is the Developer ID edition's, so never install it
# over ~/Applications/kvoice.app (the release documentation, "Mac App Store edition").
local_signing_identity="kvoice Local Signing"
developer_id_team="${KVOICE_DEVELOPER_ID_TEAM:-${APPLE_TEAM_ID:-}}"
case "$developer_id_team" in
    "") team_pattern='[A-Z0-9]\{10\}' ;;
    *[!A-Z0-9]*) echo "Not a team ID: $developer_id_team" >&2; exit 2 ;;
    *) team_pattern="$developer_id_team" ;;
esac
code_sign_identity="${KVOICE_CODE_SIGN_IDENTITY:-}"
if [ -z "$code_sign_identity" ] && [ "$configuration" = "Release" ]; then
    # `-v` here: a Developer ID is Apple-issued and trusted, and a revoked or
    # expired one must not be picked.
    code_sign_identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n "s/^ *[0-9][0-9]*) [0-9A-F]* \"\(Developer ID Application: .* ($team_pattern)\)\"\$/\1/p" \
        | head -1)"
fi
# Deliberately no `-v`: a self-signed certificate is untrusted
# (CSSMERR_TP_NOT_TRUSTED) and so is excluded from "valid identities only",
# but codesign signs with it happily and that is all this needs.
if [ -z "$code_sign_identity" ]; then
    if security find-identity -p codesigning 2>/dev/null \
        | grep -q "$local_signing_identity"; then
        code_sign_identity="$local_signing_identity"
    else
        code_sign_identity="-"
    fi
fi
echo "Signing with identity: $code_sign_identity" >&2

# A Developer ID certificate's common name ends in its team id; the build
# records it as the signature's TeamIdentifier. The local and ad-hoc
# identities have no team.
development_team=""
case "$code_sign_identity" in
    "Developer ID Application: "*" ("??????????")")
        development_team="${code_sign_identity##* (}"
        development_team="${development_team%)}"
        ;;
esac

# Release signs with a secure timestamp (Config/Release.xcconfig). The
# xcconfig reaches only the app target; the command line reaches the
# SwiftPM resource bundles nested in the app as well, so every signature in
# the bundle carries one. Without the network a real identity then fails
# to sign; ad-hoc ignores the flag. Bench is never distributed and keeps
# signing offline.
sign_flags=""
case "$configuration" in
    Release) sign_flags="--timestamp" ;;
esac

# A release build takes its version from the tag and its build number from
# the Actions run (Scripts/release_version.sh); development builds keep the
# values in Config/Base.xcconfig. Command-line settings override xcconfig.
version_overrides=""
if [ -n "${KVOICE_MARKETING_VERSION:-}" ]; then
    version_overrides="MARKETING_VERSION=$KVOICE_MARKETING_VERSION"
fi
if [ -n "${KVOICE_BUILD_NUMBER:-}" ]; then
    version_overrides="$version_overrides CURRENT_PROJECT_VERSION=$KVOICE_BUILD_NUMBER"
fi

# shellcheck disable=SC2086 # $version_overrides is a deliberate word list.
exec xcodebuild \
    -project Kvoice.xcodeproj \
    -scheme kvoice \
    -configuration "$configuration" \
    -sdk macosx \
    -derivedDataPath "$derived_data_path" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="$development_team" \
    CODE_SIGN_IDENTITY="$code_sign_identity" \
    OTHER_CODE_SIGN_FLAGS="$sign_flags" \
    $version_overrides \
    build
