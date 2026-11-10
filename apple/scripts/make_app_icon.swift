// SPDX-License-Identifier: GPL-3.0-only
//
// Draws the Trillium app icon (three petals over three leaves, like the
// trillium flower and the in-app TrilliumMark) with CoreGraphics and writes
// every PNG an AppIcon.appiconset needs. No image assets or third-party art.
//
//   swift apple/scripts/make_app_icon.swift apple/App/Shared/Assets.xcassets/AppIcon.appiconset
//
// iOS gets one full-bleed 1024 px square (the system applies the mask);
// macOS gets the rounded-square shape with margins, at all ten sizes.

import AppKit
import CoreGraphics
import Foundation

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ c: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: c as CFArray, locations: nil)!
}

/// Pointed leaf / rounded petal from the origin along +x, length `l`, half-width `w`.
func blade(length l: CGFloat, width w: CGFloat, round: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: .zero)
    p.addCurve(to: CGPoint(x: l, y: 0), control1: CGPoint(x: l * 0.15, y: w * 1.25),
               control2: CGPoint(x: l * round, y: w * 1.1))
    p.addCurve(to: .zero, control1: CGPoint(x: l * round, y: -w * 1.1),
               control2: CGPoint(x: l * 0.15, y: -w * 1.25))
    return p
}

/// The artwork in a unit square of side `s`, centred at (s/2, s/2).
func drawFlower(_ ctx: CGContext, side s: CGFloat) {
    let c = CGPoint(x: s / 2, y: s / 2 - s * 0.01)
    func each(_ angles: [CGFloat], _ path: CGPath, _ colors: [CGColor], shadow: CGFloat) {
        for a in angles {
            ctx.saveGState()
            ctx.translateBy(x: c.x, y: c.y)
            ctx.rotate(by: a * .pi / 180)
            ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.006), blur: s * shadow, color: rgb(0x000000, 0.35))
            ctx.addPath(path)
            ctx.clip()
            ctx.drawLinearGradient(gradient(colors), start: .zero, end: CGPoint(x: s * 0.42, y: 0), options: [])
            ctx.restoreGState()
        }
    }
    // Leaves between the petals.
    each([150, 270, 30], blade(length: s * 0.40, width: s * 0.105, round: 0.80),
         [rgb(0x1E6B45), rgb(0x3FA66A)], shadow: 0.02)
    // Petals.
    each([90, 210, 330], blade(length: s * 0.37, width: s * 0.13, round: 0.98),
         [rgb(0xB24BD8), rgb(0xF07AB4)], shadow: 0.025)
    // Centre.
    let r = s * 0.07
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ctx.clip()
    ctx.drawRadialGradient(gradient([rgb(0xFFF2A8), rgb(0xF5B921)]), startCenter: CGPoint(x: c.x - r * 0.3, y: c.y + r * 0.3),
                           startRadius: 0, endCenter: c, endRadius: r, options: [])
    ctx.restoreGState()
}

func background(_ ctx: CGContext, _ rect: CGRect) {
    ctx.drawLinearGradient(gradient([rgb(0x241A4A), rgb(0x0E1B2E)]),
                           start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
}

func render(pixels: Int, mac: Bool) -> Data {
    let s = CGFloat(pixels)
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    if mac {
        // macOS 11+ icon grid: 824/1024 rounded square, corner ≈ 22.4 % of its side.
        let inset = s * 100 / 1024
        let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let shape = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.2237, cornerHeight: rect.width * 0.2237, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.02, color: rgb(0x000000, 0.4))
        ctx.addPath(shape)
        ctx.setFillColor(rgb(0x0E1B2E))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        background(ctx, rect)
        ctx.translateBy(x: inset, y: inset)
        drawFlower(ctx, side: rect.width)
        ctx.restoreGState()
    } else {
        background(ctx, CGRect(x: 0, y: 0, width: s, height: s))
        drawFlower(ctx, side: s)
    }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

struct Entry: Encodable {
    var filename: String
    var idiom: String
    var platform: String?
    var scale: String
    var size: String
}

var images: [Entry] = []
try render(pixels: 1024, mac: false).write(to: outDir.appendingPathComponent("icon-ios-1024.png"))
images.append(Entry(filename: "icon-ios-1024.png", idiom: "universal", platform: "ios", scale: "1x", size: "1024x1024"))
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon-mac-\(pt)@\(scale)x.png"
        try render(pixels: pt * scale, mac: true).write(to: outDir.appendingPathComponent(name))
        images.append(Entry(filename: name, idiom: "mac", platform: nil, scale: "\(scale)x", size: "\(pt)x\(pt)"))
    }
}

struct Info: Encodable { var author = "xcode"; var version = 1 }
struct Contents: Encodable { var images: [Entry]; var info = Info() }
let enc = JSONEncoder()
enc.outputFormatting = [.prettyPrinted, .sortedKeys]
try enc.encode(Contents(images: images)).write(to: outDir.appendingPathComponent("Contents.json"))
let catalog = outDir.deletingLastPathComponent().appendingPathComponent("Contents.json")
try Data("{\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }\n}\n".utf8).write(to: catalog)
print("wrote \(images.count) icons to \(outDir.path)")
