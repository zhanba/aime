// 生成输入法菜单栏图标（照鼠须管 rime.pdf 的形态）：
// 纯黑矢量 PDF，圆角方块 + "ā" 字形 even-odd 镂空。
// macOS 12.4+ 对纯黑白的输入法图标自动做明暗/选中反色，不需要 TISIconIsTemplate。
import AppKit
import CoreText

let size: CGFloat = 16
var mediaBox = CGRect(x: 0, y: 0, width: size, height: size)
let out = CommandLine.arguments[1]
let ctx = CGContext(URL(fileURLWithPath: out) as CFURL, mediaBox: &mediaBox, nil)!
ctx.beginPDFPage(nil)

// 圆角方块
let inset: CGFloat = 0.5
let box = CGPath(
    roundedRect: mediaBox.insetBy(dx: inset, dy: inset),
    cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)

// "ā" 字形轮廓（ā = U+0101，SF 有预组合字形）
let font = CTFontCreateWithName("SFPro-Semibold" as CFString, 12.5, nil)
var chars: [UniChar] = [0x0101]
var glyphs: [CGGlyph] = [0]
guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 1), glyphs[0] != 0,
      let glyphPath = CTFontCreatePathForGlyph(font, glyphs[0], nil)
else { fatalError("no glyph for ā") }
let gb = glyphPath.boundingBox
// 居中（按字形实际边界，含上方的横线）
var t = CGAffineTransform(
    translationX: (size - gb.width) / 2 - gb.minX,
    y: (size - gb.height) / 2 - gb.minY)
let centered = glyphPath.copy(using: &t)!

// even-odd：方块填黑，字形镂空（'a' 的内孔会重新填黑，正确）
let combined = CGMutablePath()
combined.addPath(box)
combined.addPath(centered)
ctx.setFillColor(CGColor(gray: 0, alpha: 1))
ctx.addPath(combined)
ctx.fillPath(using: .evenOdd)

ctx.endPDFPage()
ctx.closePDF()
print("wrote \(out)")
