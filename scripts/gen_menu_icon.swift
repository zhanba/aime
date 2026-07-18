// 生成菜单栏图标（纯黑矢量 PDF，与 App 图标同一套 "a + 声波调号" 造型）：
// 1. aime-menu-icon.pdf  —— 输入法用：圆角方块 even-odd 镂空（照鼠须管 rime.pdf 的形态）。
//    macOS 12.4+ 对纯黑白的输入法图标自动做明暗/选中反色，不需要 TISIconIsTemplate。
// 2. aime-menu-glyph.pdf —— 主 app 菜单栏空闲态用：无框实心字形，代码里作 template image 加载。
//
// 用法：swift scripts/gen_menu_icon.swift Resources/aime-menu-icon.pdf Resources/aime-menu-glyph.pdf
import AppKit
import CoreText

let size: CGFloat = 16

// 'a' 字形路径（不含调号），缩放到指定 x 高度，水平居中，底边于 bottomY
func aPath(xHeight: CGFloat, bottomY: CGFloat) -> CGPath {
    let font = CTFontCreateWithName("SFPro-Semibold" as CFString, 12, nil)
    var chars: [UniChar] = [0x61]
    var glyphs: [CGGlyph] = [0]
    guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 1), glyphs[0] != 0,
          let raw = CTFontCreatePathForGlyph(font, glyphs[0], nil)
    else { fatalError("no glyph for a") }
    let bb = raw.boundingBox
    let s = xHeight / bb.height
    var t = CGAffineTransform.identity
        .translatedBy(x: size / 2 - bb.midX * s, y: bottomY - bb.minY * s)
        .scaledBy(x: s, y: s)
    return raw.copy(using: &t)!
}

// 三根声波小竖条（胶囊），中线对齐，整体水平居中
func wavePath(midY: CGFloat, barW: CGFloat, gap: CGFloat, heights: [CGFloat]) -> CGPath {
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    let p = CGMutablePath()
    var x = size / 2 - total / 2
    for h in heights {
        p.addPath(CGPath(roundedRect: CGRect(x: x, y: midY - h / 2, width: barW, height: h),
                         cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
        x += barW + gap
    }
    return p
}

func writePDF(to path: String, draw: (CGContext) -> Void) {
    var mediaBox = CGRect(x: 0, y: 0, width: size, height: size)
    let ctx = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &mediaBox, nil)!
    ctx.beginPDFPage(nil)
    draw(ctx)
    ctx.endPDFPage()
    ctx.closePDF()
    print("wrote \(path)")
}

// —— 输入法版：方块镂空 ——
// 布局：a 高 6.2 + 间距 1.0 + 声波高 2.4，整体在 16pt 内居中
do {
    let aH: CGFloat = 6.2
    let waveH: CGFloat = 2.4
    let gap: CGFloat = 1.0
    let bottom = (size - (aH + gap + waveH)) / 2
    writePDF(to: CommandLine.arguments[1]) { ctx in
        let box = CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
        let combined = CGMutablePath()
        combined.addPath(box)
        combined.addPath(aPath(xHeight: aH, bottomY: bottom))
        combined.addPath(wavePath(midY: bottom + aH + gap + waveH / 2,
                                  barW: 1.3, gap: 0.9, heights: [1.5, 2.4, 1.9]))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.addPath(combined)
        ctx.fillPath(using: .evenOdd)
    }
}

// —— 主 app 版：无框实心字形，比方块版大一号 ——
do {
    let aH: CGFloat = 8.2
    let waveH: CGFloat = 3.2
    let gap: CGFloat = 1.2
    let bottom = (size - (aH + gap + waveH)) / 2
    writePDF(to: CommandLine.arguments[2]) { ctx in
        let combined = CGMutablePath()
        combined.addPath(aPath(xHeight: aH, bottomY: bottom))
        combined.addPath(wavePath(midY: bottom + aH + gap + waveH / 2,
                                  barW: 1.7, gap: 1.2, heights: [2.0, 3.2, 2.5]))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.addPath(combined)
        ctx.fillPath(using: .evenOdd)
    }
}
