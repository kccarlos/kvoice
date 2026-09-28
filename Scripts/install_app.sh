#!/bin/sh
# Build the signed Debug app and install it for manual verification.
# Wraps the steps in Docs/Build.md so every install is done the same way:
# build, copy with ditto (never cp -R), verify the signature, and say whether
# the Accessibility/Microphone grants will have survived.
set -eu
cd "$(dirname "$0")/.."

configuration="${1:-Debug}"
built=".build/xcode-derived/Build/Products/$configuration/kvoice.app"
target="${KVOICE_INSTALL_PATH:-$HOME/Applications/kvoice.app}"

# The App Store edition (ADR-026) shares the bundle identifier with the
# Developer ID edition: installed over the development copy it would replace
# it, and its TCC grants, Launch at Login registration and defaults would
# collide with the installed copy's. Refuse unless a separate path is named — and
# even then quit-by-ID below would quit the development copy too.
if [ "$configuration" = "AppStore" ] && [ -z "${KVOICE_INSTALL_PATH:-}" ]; then
    echo "install: refusing to install the AppStore build over $target (same bundle identifier)." >&2
    echo "         Build it with ./Scripts/build_app.sh AppStore and test it on a separate macOS user or VM (Docs/Build.md, "Configurations")." >&2
    exit 2
fi

./Scripts/build_app.sh "$configuration"

mkdir -p "$(dirname "$target")"
if pgrep -xq kvoice; then
    echo "install: quitting the running kvoice"
    # Quitting by bundle ID succeeds silently when the running copy has a
    # different ID (a build from before 2026-09-27), so check, then kill.
    osascript -e 'tell application id "io.github.kccarlos.kvoice" to quit' >/dev/null 2>&1 || true
    sleep 1
    if pgrep -xq kvoice; then
        pkill -x kvoice || true
        sleep 1
    fi
fi
rm -rf "$target"
ditto "$built" "$target"
codesign --verify --deep --strict --verbose=2 "$target"

authority=$(codesign -dvvv "$target" 2>&1 | grep '^Authority=' | head -1 | cut -d= -f2-)
if [ -n "$authority" ]; then
    echo "install: signed by '$authority'; existing TCC grants persist across rebuilds."
else
    echo "install: AD-HOC signature — the Accessibility/Microphone grants are invalidated."
    echo "         Reset and re-grant: tccutil reset Accessibility io.github.kccarlos.kvoice; tccutil reset Microphone io.github.kccarlos.kvoice"
fi
echo "install: $target"
[ "${KVOICE_INSTALL_NO_OPEN:-}" = "1" ] || open "$target"
