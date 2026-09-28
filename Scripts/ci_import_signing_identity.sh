#!/bin/sh
# Import code-signing identities into a throwaway keychain on a CI runner
# and tell the build which identity to use (the release documentation).
#
# Each secret is a pair: the base64 of a .p12 and the .p12's password.
#   DEVELOPER_ID_P12_BASE64 / DEVELOPER_ID_P12_PASSWORD
#       An Apple "Developer ID Application" identity: the direct-download
#       DMG. The only signature notarization accepts.
#   APPLE_DISTRIBUTION_P12_BASE64 / APPLE_DISTRIBUTION_P12_PASSWORD
#       An "Apple Distribution" identity: the Mac App Store archive.
#   MAC_INSTALLER_P12_BASE64 / MAC_INSTALLER_P12_PASSWORD
#       A "Mac Installer Distribution" identity (its certificate is named
#       "3rd Party Mac Developer Installer: …" or "Mac Installer
#       Distribution: …"): it signs the .pkg App Store Connect accepts.
#       Required together with the Apple Distribution pair.
#   KVOICE_SIGNING_P12_BASE64 / KVOICE_SIGNING_P12_PASSWORD
#       A self-signed development identity, used for
#       KVOICE_CODE_SIGN_IDENTITY only when no Developer ID is given. It
#       keeps a private build's designated requirement stable across
#       builds; it is never a release signature (the release workflow
#       refuses to publish unless a Developer ID was imported).
#
# With no secret at all the script prints `KVOICE_CODE_SIGN_IDENTITY=-`
# and the build signs ad-hoc, which is what a pull request or a fork gets:
# still a valid seal, just not a stable one.
#
# Output: KEY=VALUE lines for `>> "$GITHUB_ENV"`:
#   KVOICE_CODE_SIGN_IDENTITY   the Developer ID's (or self-signed) common
#                               name, or "-"
#   KVOICE_NOTARIZE             true only when a Developer ID was imported
#   KVOICE_CI_KEYCHAIN          path of the temporary keychain (for cleanup),
#                               printed as soon as the keychain exists
#
# The Apple intermediate certificates the identities chain to (Developer
# ID G2, Worldwide Developer Relations G3) are added to the same keychain,
# checked against pinned SHA-256 digests, so the chain is complete whether
# or not the runner image carries them.
#
# No password reaches the log: each p12 is decoded to a file that is
# deleted on exit, and the keychain password is a random string used only
# inside this script. `set -x` must never be added here.
set -eu

have_developer_id=false
have_distribution=false
[ -n "${DEVELOPER_ID_P12_BASE64:-}" ] && have_developer_id=true
[ -n "${APPLE_DISTRIBUTION_P12_BASE64:-}" ] && have_distribution=true
if [ "$have_distribution" = true ] && [ -z "${MAC_INSTALLER_P12_BASE64:-}" ]; then
    echo "ci_import_signing_identity: APPLE_DISTRIBUTION_P12_BASE64 is set but MAC_INSTALLER_P12_BASE64 is not; the App Store package needs both" >&2
    exit 1
fi

if [ "$have_developer_id" = false ] && [ "$have_distribution" = false ] \
    && [ -z "${KVOICE_SIGNING_P12_BASE64:-}" ]; then
    echo "ci_import_signing_identity: no signing secret; the build signs ad-hoc" >&2
    echo "KVOICE_CODE_SIGN_IDENTITY=-"
    echo "KVOICE_NOTARIZE=false"
    exit 0
fi

workdir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/kvoice-signing.XXXXXX")"
trap 'rm -f "$workdir"/*.p12 "$workdir"/*.cer' EXIT

keychain="$workdir/kvoice-ci.keychain-db"
keychain_password="$(openssl rand -hex 24)"
security create-keychain -p "$keychain_password" "$keychain"
# Printed now, not at the end: the caller appends stdout to $GITHUB_ENV as
# it is written, so even if a later step here fails, the always-run cleanup
# (ci_remove_signing_identity.sh) finds and deletes the keychain.
echo "KVOICE_CI_KEYCHAIN=$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"

# import_p12 <name> <base64> <password>
import_p12() {
    p12="$workdir/$1.p12"
    printf '%s' "$2" | base64 --decode > "$p12"
    # -T lets these tools use the key without a UI prompt; -A would allow
    # every tool, which is more than the build needs.
    security import "$p12" -k "$keychain" -P "$3" \
        -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild \
        -T /usr/bin/productsign -T /usr/bin/pkgbuild >/dev/null
    rm -f "$p12"
    echo "ci_import_signing_identity: imported the $1 .p12" >&2
}

if [ "$have_developer_id" = true ]; then
    import_p12 developer-id "$DEVELOPER_ID_P12_BASE64" "${DEVELOPER_ID_P12_PASSWORD:-}"
elif [ -n "${KVOICE_SIGNING_P12_BASE64:-}" ]; then
    import_p12 self-signed "$KVOICE_SIGNING_P12_BASE64" "${KVOICE_SIGNING_P12_PASSWORD:-}"
fi
if [ "$have_distribution" = true ]; then
    import_p12 apple-distribution "$APPLE_DISTRIBUTION_P12_BASE64" "${APPLE_DISTRIBUTION_P12_PASSWORD:-}"
    import_p12 mac-installer "$MAC_INSTALLER_P12_BASE64" "${MAC_INSTALLER_P12_PASSWORD:-}"
fi

# The intermediates, pinned. A download failure is not fatal (the hosted
# images ship them); a digest mismatch is.
add_intermediate() {
    cer="$workdir/$1"
    if ! curl -fsSL --retry 3 -o "$cer" "https://www.apple.com/certificateauthority/$1"; then
        echo "ci_import_signing_identity: could not download $1; relying on the runner's copy" >&2
        return 0
    fi
    actual="$(shasum -a 256 "$cer" | cut -d' ' -f1)"
    if [ "$actual" != "$2" ]; then
        echo "ci_import_signing_identity: $1 has SHA-256 $actual, expected $2; refusing it" >&2
        exit 1
    fi
    security import "$cer" -k "$keychain" >/dev/null 2>&1 || true
}
add_intermediate DeveloperIDG2CA.cer f16cd3c54c7f83cea4bf1a3e6a0819c8aaa8e4a1528fd144715f350643d2df3a
add_intermediate AppleWWDRCAG3.cer dcf21878c77f4198e4b4614f03d696d89c66c66008d4244e1b99161aac91601f

security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null

# Put the new keychain first in the search list so codesign and xcodebuild
# resolve the identities by name; keep the existing entries so system
# roots still load.
existing="$(security list-keychains -d user | tr -d '"' | tr '\n' ' ')"
# shellcheck disable=SC2086 # the list is meant to split on whitespace.
security list-keychains -d user -s "$keychain" $existing

# Deliberately no `-v`: the self-signed identity is untrusted and would be
# excluded from "valid identities only" (the signing documentation).
identities="$(security find-identity -p codesigning "$keychain" \
    | sed -n 's/^ *[0-9][0-9]*) [0-9A-F]* "\(.*\)"$/\1/p' | sort -u)"

identity="-"
notarize=false
if [ "$have_developer_id" = true ]; then
    identity="$(printf '%s\n' "$identities" | grep '^Developer ID Application: ' | head -1 || true)"
    if [ -z "$identity" ]; then
        echo "ci_import_signing_identity: DEVELOPER_ID_P12_BASE64 holds no 'Developer ID Application' identity" >&2
        exit 1
    fi
    notarize=true
elif [ -n "${KVOICE_SIGNING_P12_BASE64:-}" ]; then
    identity="$(printf '%s\n' "$identities" | grep -v -e '^Apple Distribution: ' -e '^$' | head -1 || true)"
    if [ -z "$identity" ]; then
        echo "ci_import_signing_identity: KVOICE_SIGNING_P12_BASE64 holds no code-signing identity" >&2
        exit 1
    fi
fi
if [ "$have_distribution" = true ]; then
    printf '%s\n' "$identities" | grep -q '^Apple Distribution: ' || {
        echo "ci_import_signing_identity: APPLE_DISTRIBUTION_P12_BASE64 holds no 'Apple Distribution' identity" >&2
        exit 1
    }
    # Installer identities are not code-signing ones; list every identity.
    security find-identity "$keychain" \
        | grep -q -e '"3rd Party Mac Developer Installer: ' -e '"Mac Installer Distribution: ' || {
        echo "ci_import_signing_identity: MAC_INSTALLER_P12_BASE64 holds no Mac Installer Distribution identity" >&2
        exit 1
    }
    echo "ci_import_signing_identity: Apple Distribution and Mac Installer Distribution identities ready" >&2
fi

echo "ci_import_signing_identity: signing identity '$identity'" >&2
echo "KVOICE_CODE_SIGN_IDENTITY=$identity"
echo "KVOICE_NOTARIZE=$notarize"
