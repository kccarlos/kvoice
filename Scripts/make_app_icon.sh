#!/bin/sh
set -eu

# Regenerates Apps/KvoiceApp/Resources/AppIcon.icns from AppIcon.svg.
#
# The .icns is committed so an ordinary build needs no rasterizer, but it is
# generated output: edit the SVG and re-run this, never hand-edit the .icns.
# To change the icon's colour, edit the two gradient stops in AppIcon.svg.

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

source_svg="Apps/KvoiceApp/Resources/AppIcon.svg"
output_icns="Apps/KvoiceApp/Resources/AppIcon.icns"
# A PNG for the README as well: GitHub can render SVG, but it strips filters and
# other features, so a raster from the same source is the predictable option.
output_png="Docs/assets/kvoice-icon.png"

if [ ! -f "$source_svg" ]; then
    echo "Missing $source_svg" >&2
    exit 1
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
iconset_dir="$work_dir/AppIcon.iconset"

echo "Compiling the renderer" >&2
swiftc -O Scripts/AppIconRenderer.swift -o "$work_dir/AppIconRenderer"

echo "Rendering ${source_svg}" >&2
"$work_dir/AppIconRenderer" "$source_svg" "$iconset_dir"

echo "Packing ${output_icns}" >&2
iconutil --convert icns "$iconset_dir" --output "$output_icns"

echo "Copying ${output_png}" >&2
mkdir -p "$(dirname "$output_png")"
cp "$iconset_dir/icon_256x256@2x.png" "$output_png"

echo "Wrote $output_icns and $output_png" >&2
