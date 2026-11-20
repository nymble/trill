// SPDX-License-Identifier: GPL-3.0-only
// Flatten a PNG to opaque 8-bit sRGB RGB, or print luma stats.
//
//   swift flatten_png.swift IN.png OUT.png [R,G,B]
//   swift flatten_png.swift --stats FILE.png
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let stage = (r: 12, g: 12, b: 13)

func fail(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("flatten_png: \(msg)\n".utf8))
    exit(code)
}

func loadCG(_ url: URL) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        fail("cannot read \(url.path)")
    }
    return image
}

func writeRGB(_ image: CGImage, to url: URL) {
    let w = image.width
    let h = image.height
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { fail("no sRGB") }
    guard let ctx = CGContext(
        data: nil,
        width: w,
        height: h,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { fail("cannot allocate \(w)x\(h) RGB context") }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let out = ctx.makeImage() else { fail("cannot snapshot context") }
    // Re-draw into a 24-bit (no alpha) context so the PNG has color type 2.
    guard let rgb = CGContext(
        data: nil,
        width: w,
        height: h,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { fail("cannot allocate 24-bit context") }
    rgb.draw(out, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let final = rgb.makeImage() else { fail("cannot snapshot 24-bit context") }
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(dest, final, nil)
    guard CGImageDestinationFinalize(dest) else { fail("cannot finalize \(url.path)") }
}

func flatten(_ src: URL, to dest: URL, background: (r: Int, g: Int, b: Int)) {
    let image = loadCG(src)
    let w = image.width
    let h = image.height
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { fail("no sRGB") }
    guard let ctx = CGContext(
        data: nil,
        width: w,
        height: h,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("cannot allocate context") }
    ctx.setFillColor(CGColor(
        srgbRed: CGFloat(background.r) / 255,
        green: CGFloat(background.g) / 255,
        blue: CGFloat(background.b) / 255,
        alpha: 1
    ))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let composed = ctx.makeImage() else { fail("cannot composite") }
    writeRGB(composed, to: dest)
}

func printStats(_ url: URL) {
    let image = loadCG(url)
    let w = image.width
    let h = image.height
    let hasAlpha = image.alphaInfo != .none && image.alphaInfo != .noneSkipLast && image.alphaInfo != .noneSkipFirst
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { fail("no sRGB") }
    guard let ctx = CGContext(
        data: nil,
        width: w,
        height: h,
        bitsPerComponent: 8,
        bytesPerRow: w * 4,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let data = ctx.data else { fail("cannot sample \(url.path)") }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let ptr = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
    let step = min(w, h) >= 800 ? 2 : 1
    var n = 0
    var sum = 0.0
    var sum2 = 0.0
    var near = 0
    var minX = w, minY = h, maxX = -1, maxY = -1
    // Stage-black is (12,12,13); use those for the fill bbox.
    let sr = 12, sg = 12, sb = 13
    for y in stride(from: 0, to: h, by: step) {
        for x in stride(from: 0, to: w, by: step) {
            let i = ((h - 1 - y) * w + x) * 4 // CG context is flipped vs UI if we care; bbox still works
            // Context origin is bottom-left. Use top-left friendly y for fractions only via min/max.
            let r = Int(ptr[i]), g = Int(ptr[i + 1]), b = Int(ptr[i + 2])
            let yv = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
            n += 1
            sum += yv
            sum2 += yv * yv
            if yv < 8.0 { near += 1 }
            if abs(r - sr) > 6 || abs(g - sg) > 6 || abs(b - sb) > 6 {
                if x < minX { minX = x }
                if y < minY { minY = y }
                if x > maxX { maxX = x }
                if y > maxY { maxY = y }
            }
        }
    }
    let mean = n > 0 ? sum / Double(n) : 0
    var variance = n > 0 ? (sum2 / Double(n)) - (mean * mean) : 0
    if variance < 0 { variance = 0 }
    let cw: Double
    let ch: Double
    if maxX < 0 {
        cw = 0
        ch = 0
    } else {
        cw = min(Double(maxX - minX + step) / Double(w), 1)
        ch = min(Double(maxY - minY + step) / Double(h), 1)
    }
    print(
        "w=\(w) h=\(h) color_type=\(hasAlpha ? 6 : 2) mean=\(mean) variance=\(variance) " +
        "near_black=\(n > 0 ? Double(near) / Double(n) : 1) content_w=\(cw) content_h=\(ch) " +
        "has_alpha=\(hasAlpha ? 1 : 0)"
    )
}

let args = CommandLine.arguments
if args.count >= 3, args[1] == "--stats" {
    printStats(URL(fileURLWithPath: args[2]))
} else if args.count >= 3 {
    var bg = stage
    if args.count >= 4 {
        let parts = args[3].split(separator: ",").compactMap { Int($0) }
        if parts.count == 3 { bg = (parts[0], parts[1], parts[2]) }
    }
    flatten(URL(fileURLWithPath: args[1]), to: URL(fileURLWithPath: args[2]), background: bg)
} else {
    fail("usage: flatten_png.swift IN.png OUT.png [R,G,B]  |  flatten_png.swift --stats FILE.png", code: 2)
}
