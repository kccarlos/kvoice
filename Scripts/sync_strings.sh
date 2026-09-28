#!/bin/sh
# Syncs the String Catalogs with the strings the compiler found in the code.
#
# Xcode's IDE does this on every build; `xcodebuild` does not, so kvoice runs
# the same tool (`xcstringstool sync`) over the `.stringsdata` files that
# `SWIFT_EMIT_LOC_STRINGS = YES` (Config/Base.xcconfig) makes the compiler
# write during `./Scripts/build_app.sh`. New keys are added with their English
# value; keys no longer in the code are marked `"extractionState" : "stale"`,
# which `StringCatalogTests` then reports. Translate the new keys in the
# catalog afterwards (Docs/Localization.md).
#
# Usage: ./Scripts/sync_strings.sh [--build]
#   --build   run ./Scripts/build_app.sh Debug first (otherwise the last
#             Debug build's .stringsdata is used, so build after code changes).
set -eu

cd "$(dirname "$0")/.."

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
derived_data_path="${KVOICE_DERIVED_DATA_PATH:-.build/xcode-derived}"
tool="$DEVELOPER_DIR/usr/bin/xcstringstool"

if [ "${1:-}" = "--build" ]; then
    ./Scripts/build_app.sh Debug >/dev/null
fi

intermediates="$derived_data_path/Build/Intermediates.noindex"
# Xcode lays the package targets out as either
# `kvoice.build/Debug/KvoiceUI.build` or (a fresh derived-data folder under
# Xcode 26) `Kvoice.build/Debug/KvoiceUI-t.build`; take whichever exists.
ui_build=""
for candidate in \
    "$intermediates/kvoice.build/Debug/KvoiceUI.build" \
    "$intermediates/Kvoice.build/Debug/KvoiceUI-t.build"; do
    if [ -d "$candidate" ]; then
        ui_build="$candidate"
        break
    fi
done
app_build="$intermediates/Kvoice.build/Debug/kvoice.build"
if [ -z "$ui_build" ] || [ ! -d "$app_build" ]; then
    echo "No Debug build products under $derived_data_path; run ./Scripts/build_app.sh Debug first (or pass --build)." >&2
    exit 2
fi

sync_catalog() {
    catalog="$1"
    build_dir="$2"
    # shellcheck disable=SC2046
    "$tool" sync "$catalog" --stringsdata $(find "$build_dir" -name '*.stringsdata' ! -name 'ExtractedAppShortcutsMetadata.stringsdata')
    echo "synced $catalog"
}

# KvoiceUI: SwiftUI literals and String(localized:bundle: .module) calls.
sync_catalog Packages/KvoiceUI/Sources/KvoiceUI/Resources/Localizable.xcstrings "$ui_build"
# The app shell: String(localized:table: "Shell") calls in Apps/KvoiceApp.
sync_catalog Apps/KvoiceApp/Resources/Shell.xcstrings "$app_build"
# DomainCopy.xcstrings is keyed by runtime values (KvoiceDomain's English
# sentences) and is maintained by hand; DomainCopyTests checks its coverage.
