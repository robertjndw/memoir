#!/usr/bin/env swift
// Draws the DMG window background at 1x and 2x and combines them into one
// multi-resolution TIFF, so Finder picks the sharp one on Retina screens.
//
//   swift scripts/dmg/make-background.swift scripts/dmg/background.tiff
//
// The geometry has to match scripts/dmg/settings.py: a 660x400 window with the
// icons centered at x=165 and x=495, y=160 (from the top).
import AppKit

let width: CGFloat = 660
let height: CGFloat = 400
let iconY: CGFloat = 160

let output = CommandLine.arguments.dropFirst().first ?? "background.tiff"

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(width * scale),
        pixelsHigh: Int(height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    // Saves the 2x image at 144 dpi, so both pages describe the same 660x400
    // point size and only differ in pixel density.
    rep.size = NSSize(width: width, height: height)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let bounds = NSRect(x: 0, y: 0, width: width, height: height)
    // AppKit's origin is bottom left, the settings file's is top left.
    let y = height - iconY
    let appCenter = NSPoint(x: 165, y: y)
    let applicationsCenter = NSPoint(x: 495, y: y)

    // Light on purpose: Finder draws the icon labels in dark text over a
    // custom background, whatever the system appearance.
    NSColor(srgbRed: 0.99, green: 0.975, blue: 0.965, alpha: 1).setFill()
    bounds.fill()

    // The waveform's pink and orange from the app icon. Keep them faint or the labels get hard to read.
    func bloom(_ center: NSPoint, radius: CGFloat, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, alpha: CGFloat) {
        let color = NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
        NSGradient(colors: [color, color.withAlphaComponent(0)])!
            .draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
    }
    bloom(NSPoint(x: 40, y: height + 20), radius: 360, 1.00, 0.23, 0.42, alpha: 0.22)
    bloom(NSPoint(x: width + 30, y: height - 40), radius: 300, 1.00, 0.62, 0.18, alpha: 0.22)
    bloom(NSPoint(x: width * 0.65, y: -80), radius: 340, 1.00, 0.45, 0.30, alpha: 0.16)
    bloom(NSPoint(x: 60, y: -40), radius: 220, 1.00, 0.62, 0.18, alpha: 0.12)

    // Brighten the spots under the icons so they don't sit on the color.
    for center in [appCenter, applicationsCenter] {
        bloom(center, radius: 120, 1, 1, 1, alpha: 0.85)
    }

    let tail: CGFloat = 258
    let neck: CGFloat = 370
    let tip: CGFloat = 404
    let sharp = CGMutablePath()
    sharp.addLines(between: [
        CGPoint(x: tail, y: y - 0.75),
        CGPoint(x: neck, y: y - 3.5),
        CGPoint(x: neck, y: y - 14),
        CGPoint(x: tip, y: y),
        CGPoint(x: neck, y: y + 14),
        CGPoint(x: neck, y: y + 3.5),
        CGPoint(x: tail, y: y + 0.75),
    ])
    sharp.closeSubpath()
    // Adding a round-joined stroke of the outline rounds off the corners.
    let arrow = sharp.union(sharp.copy(strokingWithWidth: 3, lineCap: .round, lineJoin: .round, miterLimit: 10))

    // The same orange to pink as the waveform in the app icon.
    let deep = NSColor(srgbRed: 1.0, green: 0.23, blue: 0.42, alpha: 1)
    let fade = NSGradient(colors: [
        NSColor(srgbRed: 1.0, green: 0.62, blue: 0.18, alpha: 0.0),
        NSColor(srgbRed: 1.0, green: 0.45, blue: 0.30, alpha: 0.7),
        deep,
    ], atLocations: [0, 0.45, 1], colorSpace: .sRGB)!

    let cg = NSGraphicsContext.current!.cgContext
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -2), blur: 8,
                 color: deep.withAlphaComponent(0.35).cgColor)
    // Without the transparency layer the shadow follows the clip's hard edge
    // instead of the faded gradient.
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    cg.addPath(arrow)
    cg.clip()
    fade.draw(in: NSRect(x: tail - 2, y: y - 18, width: tip - tail + 4, height: 36), angle: 0)
    cg.endTransparencyLayer()
    cg.restoreGState()

    let caption = "Drag Memoir to Applications to install"
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 0.23, green: 0.24, blue: 0.27, alpha: 0.8),
        .paragraphStyle: paragraph,
    ]
    // Not at the bottom edge: the title bar eats into the window height, and
    // Finder's path and status bars cover what's left of the bottom. Those are
    // global Finder settings, the DMG can't hide them.
    caption.draw(in: NSRect(x: 0, y: 94, width: width, height: 20), withAttributes: attributes)

    return rep.tiffRepresentation(using: .lzw, factor: 0)!
}

let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }

let oneX = directory.appendingPathComponent("background.tiff")
let twoX = directory.appendingPathComponent("background@2x.tiff")
try render(scale: 1).write(to: oneX)
try render(scale: 2).write(to: twoX)

let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.arguments = ["-cathidpicheck", oneX.path, twoX.path, "-out", output]
try tiffutil.run()
tiffutil.waitUntilExit()
exit(tiffutil.terminationStatus)
