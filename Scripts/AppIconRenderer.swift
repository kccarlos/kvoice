import AppKit

// Rasterizes an SVG into the PNG set that `iconutil` expects.
//
// Invoked by Scripts/make_app_icon.sh; not part of the app or any package
// target. NSImage renders SVG natively on this platform, including gradients and
// filters, so no external rasterizer is needed.
//
// Usage: AppIconRenderer <input.svg> <output.iconset directory>

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    die("usage: AppIconRenderer <input.svg> <output.iconset>")
}

/// The set macOS expects in an `.iconset`. Each entry is the logical point size
/// and the scale, which together give the pixel dimensions.
let variants: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2)
]

let inputURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])

guard let image = NSImage(contentsOf: inputURL) else {
    die("""
        could not load \(inputURL.path)
        A silent nil here usually means malformed XML. Check for a double hyphen \
        inside an XML comment, which is illegal and rejects the whole file.
        """)
}

try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

for variant in variants {
    let pixels = variant.points * variant.scale
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        die("could not allocate a \(pixels)x\(pixels) bitmap")
    }
    // The rep is sized in pixels, so it must also report that size in points,
    // or drawing scales by the display's backing factor and the art lands at
    // the wrong size.
    bitmap.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        die("could not create a drawing context")
    }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        die("could not encode PNG at \(pixels)x\(pixels)")
    }

    let suffix = variant.scale == 1 ? "" : "@\(variant.scale)x"
    let name = "icon_\(variant.points)x\(variant.points)\(suffix).png"
    do {
        try data.write(to: outputURL.appendingPathComponent(name))
    } catch {
        die("could not write \(name): \(error.localizedDescription)")
    }
    print("  \(name) (\(pixels)x\(pixels))")
}
