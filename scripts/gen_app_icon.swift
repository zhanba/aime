// 生成 App 图标（Resources/aime-ime.icns）：
// 深靛紫渐变圆角方块 + 白色 SF Rounded "a"，一声调号（macron）画成语音波形——
// 一个字形同时表达拼音输入与语音输入。
// ≤32px 的小尺寸下五根声波会糊掉，退化为一根实心长横（标准 ā 调号），语义不变。
//
// 用法：swift scripts/gen_app_icon.swift Resources/aime-ime.icns
import AppKit
import UniformTypeIdentifiers

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [
        CGFloat((hex >> 16) & 0xFF) / 255,
        CGFloat((hex >> 8) & 0xFF) / 255,
        CGFloat(hex & 0xFF) / 255, a])!
}

// —— 1024 基准画布上的布局 ——
let S: CGFloat = 1024
let iconRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let cornerR: CGFloat = 185.4
let aHeight: CGFloat = 400
let waveMaxH: CGFloat = 140
let waveGap: CGFloat = 40
let aBottom = (S - (aHeight + waveGap + waveMaxH)) / 2
let waveMid = aBottom + aHeight + waveGap + waveMaxH / 2
let waveFracs: [CGFloat] = [0.40, 0.76, 1.0, 0.60, 0.34]
let barW: CGFloat = 40
let barGap: CGFloat = 21

func aGlyphPath() -> CGPath {
    let base = NSFont.systemFont(ofSize: 1000, weight: .semibold)
    let desc = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
    let font = NSFont(descriptor: desc, size: 1000)!
    var chars: [UniChar] = [0x61]
    var glyphs: [CGGlyph] = [0]
    guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 1), glyphs[0] != 0,
          let raw = CTFontCreatePathForGlyph(font, glyphs[0], nil) else { fatalError("no glyph for a") }
    let bb = raw.boundingBox
    let scale = aHeight / bb.height
    var t = CGAffineTransform.identity
        .translatedBy(x: S / 2 - bb.midX * scale, y: aBottom - bb.minY * scale)
        .scaledBy(x: scale, y: scale)
    return raw.copy(using: &t)!
}

func wavePath(simplified: Bool) -> CGPath {
    let p = CGMutablePath()
    if simplified {
        // 单根长横：宽度与五根声波总宽相当，读作标准一声调号
        let w = CGFloat(waveFracs.count) * barW + CGFloat(waveFracs.count - 1) * barGap
        let h: CGFloat = 72
        p.addPath(CGPath(roundedRect: CGRect(x: S / 2 - w / 2, y: waveMid - h / 2, width: w, height: h),
                         cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
    } else {
        let total = CGFloat(waveFracs.count) * barW + CGFloat(waveFracs.count - 1) * barGap
        var x = S / 2 - total / 2
        for f in waveFracs {
            let h = max(barW, waveMaxH * f)
            p.addPath(CGPath(roundedRect: CGRect(x: x, y: waveMid - h / 2, width: barW, height: h),
                             cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
            x += barW + barGap
        }
    }
    return p
}

func draw(_ ctx: CGContext, pixelSize: Int) {
    ctx.scaleBy(x: CGFloat(pixelSize) / S, y: CGFloat(pixelSize) / S)
    let squircle = CGPath(roundedRect: iconRect, cornerWidth: cornerR, cornerHeight: cornerR, transform: nil)

    // 底：深靛紫对角渐变
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let bg = CGGradient(colorsSpace: srgb,
                        colors: [color(0x4C3DDB), color(0x171238)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 260, y: 924), end: CGPoint(x: 764, y: 100),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // 字形背后的柔光
    let glow = CGGradient(colorsSpace: srgb,
                          colors: [color(0x8B7BFF, 0.35), color(0x8B7BFF, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 540), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 540), endRadius: 460, options: [])
    ctx.restoreGState()

    // 白色 "a"
    ctx.setFillColor(color(0xFFFFFF))
    ctx.addPath(aGlyphPath())
    ctx.fillPath(using: .evenOdd)

    // 声波调号：青→紫渐变
    ctx.saveGState()
    ctx.addPath(wavePath(simplified: pixelSize <= 32))
    ctx.clip()
    let wave = CGGradient(colorsSpace: srgb,
                          colors: [color(0x5EE7FF), color(0xC4A9FF)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(wave, start: CGPoint(x: 360, y: 0), end: CGPoint(x: 664, y: 0),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func renderPNG(pixelSize: Int, to path: String) {
    let ctx = CGContext(data: nil, width: pixelSize, height: pixelSize, bitsPerComponent: 8,
                        bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx, pixelSize: pixelSize)
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                               UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/aime-ime.icns"
let iconset = NSTemporaryDirectory() + "aime-appicon-\(ProcessInfo.processInfo.processIdentifier).iconset"
try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

for pt in [16, 32, 128, 256, 512] {
    renderPNG(pixelSize: pt, to: "\(iconset)/icon_\(pt)x\(pt).png")
    renderPNG(pixelSize: pt * 2, to: "\(iconset)/icon_\(pt)x\(pt)@2x.png")
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset, "-o", out]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
try? FileManager.default.removeItem(atPath: iconset)
print("wrote \(out)")
