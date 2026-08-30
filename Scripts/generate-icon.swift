#!/usr/bin/env swift
// generate-icon.swift — Original geometric app icon for Parallax.
//
// Draws a professional, abstract holographic-board motif using CoreGraphics:
// layered translucent rectangular planes (lavender / chartreuse / yellow),
// nesting green/teal outlines, and a small ring token. No franchise imagery,
// no copyrighted assets — pure geometry.
//
// Usage:
//   swift Scripts/generate-icon.swift --output Scripts/AppIcon.appiconset
//   swift Scripts/generate-icon.swift --output Scripts/AppIcon.appiconset --single 1024
//
// Produces a complete .appiconset with Contents.json plus PNGs at every
// required macOS size. Use `iconutil -c icns` to assemble the final .icns.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Argument parsing

struct Options {
    var outputDir: String = "Scripts/AppIcon.appiconset"
    var singleSize: Int = 0 // 0 = full appiconset, >0 = one PNG at that size
}

func parseArgs(_ argv: [String]) -> Options {
    var opts = Options()
    var i = 1
    while i < argv.count {
        let arg = argv[i]
        switch arg {
        case "--output":
            if i + 1 < argv.count { opts.outputDir = argv[i + 1]; i += 2 } else { i += 1 }
        case "--single":
            if i + 1 < argv.count, let s = Int(argv[i + 1]) { opts.singleSize = s; i += 2 } else { i += 1 }
        case "--help", "-h":
            print("Usage: generate-icon.swift --output <dir> [--single <size>]")
            exit(0)
        default:
            i += 1
        }
    }
    return opts
}

// MARK: - Color helpers

func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> NSColor {
    NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
}

extension NSColor {
    var cg: CGColor {
        if let srgb = self.usingColorSpace(.sRGB) {
            return srgb.cgColor
        }
        return self.cgColor
    }
}

// MARK: - Icon drawing

/// Draw the Parallax icon into a CGContext of the given pixel size.
func drawIcon(_ ctx: CGContext, size: Int) {
    let s = CGFloat(size)
    let rect = CGRect(x: 0, y: 0, width: s, height: s)

    // 1. Background — deep navy gradient (top-left lighter, bottom-right darker).
    let bgColors = [rgba(0.10, 0.13, 0.22, 1.0).cg, rgba(0.04, 0.05, 0.10, 1.0).cg]
    let bgSpace = CGColorSpaceCreateDeviceRGB()
    if let grad = CGGradient(colorsSpace: bgSpace, colors: bgColors as CFArray,
                             locations: [0.0, 1.0]) {
        ctx.saveGState()
        ctx.addRect(rect)
        ctx.clip()
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: 0, y: s),
                               end: CGPoint(x: s, y: 0),
                               options: [])
        ctx.restoreGState()
    }

    // 2. Subtle rounded background panel (macOS icon "squircle" feel).
    let panelInset = s * 0.0
    let panelRect = rect.insetBy(dx: panelInset, dy: panelInset)
    let panelPath = CGPath(roundedRect: panelRect,
                           cornerWidth: s * 0.22, cornerHeight: s * 0.22,
                           transform: nil)
    ctx.saveGState()
    ctx.addPath(panelPath)
    ctx.clip()

    // 3. Layered translucent planes — upright, slightly slanted, overlapping.
    //    Echoes the holographic board: lavender, chartreuse, yellow regions.
    let planeColors: [(Double, Double, Double, Double)] = [
        (0.55, 0.45, 0.85, 0.38), // lavender
        (0.55, 0.82, 0.40, 0.34), // chartreuse
        (0.92, 0.82, 0.35, 0.30), // yellow
    ]
    let planeCount = planeColors.count
    let planeW = s * 0.52
    let planeH = s * 0.62
    let centerX = s * 0.5
    let baseY = s * 0.20

    for i in 0..<planeCount {
        let (r, g, b, a) = planeColors[i]
        let xOffset = (CGFloat(i) - CGFloat(planeCount - 1) / 2.0) * s * 0.14
        let x = centerX - planeW / 2.0 + xOffset
        let y = baseY + CGFloat(i) * s * 0.04
        let skew = s * 0.03 // slight slant for depth

        let planeRect = CGRect(x: x, y: y, width: planeW, height: planeH)
        ctx.saveGState()
        // Apply a slight skew transform for the elevated/slanted look.
        var transform = CGAffineTransform(translationX: 0, y: 0)
        transform = transform.concatenating(CGAffineTransform(a: 1, b: 0, c: skew / planeH, d: 1, tx: 0, ty: 0))
        ctx.concatenate(transform)
        ctx.setFillColor(rgba(r, g, b, a).cg)
        ctx.fill(planeRect)
        // Thin border on each plane.
        ctx.setStrokeColor(rgba(r, g, b, a * 1.8).cg)
        ctx.setLineWidth(max(1.0, s * 0.004))
        ctx.stroke(planeRect)
        ctx.restoreGState()
    }

    // 4. Nesting green/teal rectangular outlines (inward).
    let outlineColor = rgba(0.30, 0.85, 0.70, 0.85)
    let outlineCount = 4
    let outerW = s * 0.60
    let outerH = s * 0.70
    for i in 0..<outlineCount {
        let inset = CGFloat(i) * s * 0.06
        let w = outerW - inset * 2
        let h = outerH - inset * 2
        if w < s * 0.1 || h < s * 0.1 { break }
        let x = centerX - w / 2.0
        let y = s * 0.5 - h / 2.0 + s * 0.05
        let r = CGRect(x: x, y: y, width: w, height: h)
        ctx.saveGState()
        ctx.setStrokeColor(outlineColor.withAlphaComponent(0.85 - CGFloat(i) * 0.15).cg)
        ctx.setLineWidth(max(1.0, s * 0.005))
        ctx.stroke(r)
        ctx.restoreGState()
    }

    // 5. Small ring token (red/yellow) near the lower plane — a game piece.
    let tokenCenter = CGPoint(x: centerX + s * 0.10, y: s * 0.34)
    let tokenRadius = s * 0.055
    let tokenRing = CGPath(ellipseIn: CGRect(x: tokenCenter.x - tokenRadius,
                                             y: tokenCenter.y - tokenRadius,
                                             width: tokenRadius * 2,
                                             height: tokenRadius * 2),
                           transform: nil)
    ctx.saveGState()
    ctx.setFillColor(rgba(0.90, 0.30, 0.30, 0.90).cg)
    ctx.addPath(tokenRing)
    ctx.fillPath()
    ctx.setStrokeColor(rgba(0.95, 0.85, 0.40, 1.0).cg)
    ctx.setLineWidth(max(1.5, s * 0.008))
    ctx.addPath(tokenRing)
    ctx.strokePath()
    // Inner hole.
    let innerR = tokenRadius * 0.45
    ctx.setFillColor(rgba(0.04, 0.05, 0.10, 1.0).cg)
    ctx.fillEllipse(in: CGRect(x: tokenCenter.x - innerR,
                               y: tokenCenter.y - innerR,
                               width: innerR * 2,
                               height: innerR * 2))
    ctx.restoreGState()

    // 6. Faint horizon glow line across the middle.
    ctx.saveGState()
    let glowGrad = CGGradient(colorsSpace: bgSpace,
                              colors: [rgba(0.30, 0.85, 0.70, 0.0).cg,
                                       rgba(0.30, 0.85, 0.70, 0.25).cg,
                                       rgba(0.30, 0.85, 0.70, 0.0).cg] as CFArray,
                              locations: [0.0, 0.5, 1.0])
    if let glow = glowGrad {
        ctx.addRect(CGRect(x: 0, y: s * 0.48, width: s, height: s * 0.04))
        ctx.clip()
        ctx.drawLinearGradient(glow,
                               start: CGPoint(x: 0, y: s * 0.50),
                               end: CGPoint(x: s, y: s * 0.50),
                               options: [])
    }
    ctx.restoreGState()

    ctx.restoreGState() // panel clip
}

// MARK: - PNG rendering

func renderPNG(size: Int) -> Data {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Could not create bitmap context for size \(size)")
    }
    drawIcon(ctx, size: size)
    guard let img = ctx.makeImage() else { fatalError("Could not make image for size \(size)") }
    let bitmap = NSBitmapImageRep(cgImage: img)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode PNG for size \(size)")
    }
    return png
}

func writePNG(_ data: Data, to path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    try? data.write(to: url)
}

// MARK: - Appiconset assembly

struct IconSpec { let size: Int; let scale: String; let filename: String }

let macIconSpecs: [IconSpec] = [
    IconSpec(size: 16,  scale: "1x", filename: "icon_16x16.png"),
    IconSpec(size: 32,  scale: "2x", filename: "icon_16x16@2x.png"),
    IconSpec(size: 32,  scale: "1x", filename: "icon_32x32.png"),
    IconSpec(size: 64,  scale: "2x", filename: "icon_32x32@2x.png"),
    IconSpec(size: 128, scale: "1x", filename: "icon_128x128.png"),
    IconSpec(size: 256, scale: "2x", filename: "icon_128x128@2x.png"),
    IconSpec(size: 256, scale: "1x", filename: "icon_256x256.png"),
    IconSpec(size: 512, scale: "2x", filename: "icon_256x256@2x.png"),
    IconSpec(size: 512, scale: "1x", filename: "icon_512x512.png"),
    IconSpec(size: 1024, scale: "2x", filename: "icon_512x512@2x.png"),
]

func contentsJSON(_ specs: [IconSpec]) -> String {
    var entries: [String] = []
    for spec in specs {
        let sz = "\(spec.size)x\(spec.size)"
        entries.append("""
        {
          "filename" : "\(spec.filename)",
          "idiom" : "mac",
          "scale" : "\(spec.scale)",
          "size" : "\(sz)"
        }
        """)
    }
    return """
    {
      "images" : [
        \(entries.joined(separator: ",\n        "))
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }
    """
}

// MARK: - Main

let opts = parseArgs(CommandLine.arguments)

if opts.singleSize > 0 {
    let outPath = opts.outputDir.hasSuffix(".png") ? opts.outputDir : "\(opts.outputDir)/icon_\(opts.singleSize).png"
    let data = renderPNG(size: opts.singleSize)
    writePNG(data, to: outPath)
    print("Wrote single \(opts.singleSize)x\(opts.singleSize) PNG: \(outPath)")
    exit(0)
}

// Full appiconset.
let fm = FileManager.default
try? fm.createDirectory(atPath: opts.outputDir, withIntermediateDirectories: true)

for spec in macIconSpecs {
    let path = "\(opts.outputDir)/\(spec.filename)"
    let data = renderPNG(size: spec.size)
    writePNG(data, to: path)
    print("  \(spec.filename) (\(spec.size)x\(spec.size))")
}

let jsonPath = "\(opts.outputDir)/Contents.json"
try? contentsJSON(macIconSpecs).data(using: .utf8)?.write(to: URL(fileURLWithPath: jsonPath))
print("Wrote Contents.json")
print("App icon set assembled at: \(opts.outputDir)")
print("Build .icns with: iconutil -c icns \"\(opts.outputDir)\"")
