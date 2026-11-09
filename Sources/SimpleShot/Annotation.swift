import AppKit

enum AnnotationTool: Int, CaseIterable {
    case rect, ellipse, arrow, pen, text, mosaic

    var symbolName: String {
        switch self {
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .pen: return "scribble"
        case .text: return "textformat"
        case .mosaic: return "checkerboard.rectangle"
        }
    }

    var title: String {
        switch self {
        case .rect: return "矩形"
        case .ellipse: return "椭圆"
        case .arrow: return "箭头"
        case .pen: return "画笔"
        case .text: return "文字"
        case .mosaic: return "马赛克"
        }
    }

    /// 三档尺寸：线宽 / 字号 / 马赛克笔刷直径（单位：点）
    func size(for index: Int) -> CGFloat {
        let i = min(max(index, 0), 2)
        switch self {
        case .text: return [14, 20, 28][i]
        case .mosaic: return [12, 24, 40][i]
        default: return [2, 4, 7][i]
        }
    }
}

/// 当前选中的颜色和尺寸（应用运行期间记住上次的选择）
@MainActor
final class AnnotationStyle {
    static let shared = AnnotationStyle()

    static let palette: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1), // 红
        NSColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1), // 黄
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1), // 绿
        NSColor(srgbRed: 0.00, green: 0.48, blue: 1.00, alpha: 1), // 蓝
        NSColor(srgbRed: 0.00, green: 0.00, blue: 0.00, alpha: 1), // 黑
        NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1), // 白
    ]

    var colorIndex = 0
    var sizeIndex = 1

    var color: NSColor { AnnotationStyle.palette[colorIndex] }
}

final class Annotation {
    let tool: AnnotationTool
    let color: NSColor
    let size: CGFloat
    /// 矩形/椭圆/箭头：[起点, 终点]；画笔/马赛克：路径点
    var points: [CGPoint]
    /// 文字标注
    var text = ""
    var textRect: CGRect = .zero

    init(tool: AnnotationTool, color: NSColor, size: CGFloat, points: [CGPoint]) {
        self.tool = tool
        self.color = color
        self.size = size
        self.points = points
    }

    var isMeaningful: Bool {
        switch tool {
        case .rect, .ellipse, .arrow:
            guard let a = points.first, let b = points.last else { return false }
            return hypot(b.x - a.x, b.y - a.y) > 3
        case .pen: return points.count >= 2
        case .mosaic: return !points.isEmpty
        case .text: return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func textFont(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .medium)
    }
}

/// 绘制标注。屏幕显示和最终导出共用同一套绘制代码，保证所见即所得。
@MainActor
struct AnnotationRenderer {
    /// 整屏的像素化版本，用于马赛克
    let mosaicImage: CGImage?
    /// 视图坐标系下整张截图所占的矩形
    let canvasBounds: CGRect

    /// 文字在 NSTextField 内的水平内边距
    static let textInset: CGFloat = 2

    func draw(_ a: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(a.size)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        switch a.tool {
        case .rect:
            guard let r = boxRect(a) else { return }
            ctx.stroke(r)
        case .ellipse:
            guard let r = boxRect(a) else { return }
            ctx.strokeEllipse(in: r)
        case .arrow:
            drawArrow(a, in: ctx)
        case .pen:
            guard a.points.count >= 2 else { return }
            ctx.addLines(between: a.points)
            ctx.strokePath()
        case .mosaic:
            drawMosaic(a, in: ctx)
        case .text:
            drawText(a, in: ctx)
        }
    }

    private func boxRect(_ a: Annotation) -> CGRect? {
        guard let p = a.points.first, let q = a.points.last else { return nil }
        return CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(q.x - p.x), height: abs(q.y - p.y))
    }

    private func drawArrow(_ a: Annotation, in ctx: CGContext) {
        guard let s = a.points.first, let e = a.points.last else { return }
        let dx = e.x - s.x, dy = e.y - s.y
        let len = hypot(dx, dy)
        guard len > 1 else { return }
        let ux = dx / len, uy = dy / len
        let headLen = min(len, max(12, a.size * 4))
        let halfWidth = headLen * 0.45
        let base = CGPoint(x: e.x - ux * headLen, y: e.y - uy * headLen)

        // 箭杆
        ctx.move(to: s)
        ctx.addLine(to: CGPoint(x: base.x + ux, y: base.y + uy))
        ctx.strokePath()

        // 箭头
        let px = -uy, py = ux
        ctx.move(to: e)
        ctx.addLine(to: CGPoint(x: base.x + px * halfWidth, y: base.y + py * halfWidth))
        ctx.addLine(to: CGPoint(x: base.x - px * halfWidth, y: base.y - py * halfWidth))
        ctx.closePath()
        ctx.fillPath()
    }

    private func drawMosaic(_ a: Annotation, in ctx: CGContext) {
        guard let mosaic = mosaicImage, let first = a.points.first else { return }
        if a.points.count == 1 {
            ctx.addEllipse(in: CGRect(x: first.x - a.size / 2, y: first.y - a.size / 2,
                                      width: a.size, height: a.size))
        } else {
            ctx.addLines(between: a.points)
            ctx.replacePathWithStrokedPath()
        }
        ctx.clip()
        ctx.interpolationQuality = .none
        ctx.draw(mosaic, in: canvasBounds)
    }

    private func drawText(_ a: Annotation, in ctx: CGContext) {
        guard !a.text.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Annotation.textFont(size: a.size),
            .foregroundColor: a.color,
        ]
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let rect = a.textRect.insetBy(dx: AnnotationRenderer.textInset, dy: 0)
        NSAttributedString(string: a.text, attributes: attrs)
            .draw(in: CGRect(x: rect.minX, y: rect.minY, width: rect.width + 1000, height: rect.height))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 生成像素化图像：缩小 block 倍，绘制时用最近邻放大即得到马赛克效果
    static func pixelate(_ image: CGImage, block: Int) -> CGImage? {
        let w = max(1, image.width / block)
        let h = max(1, image.height / block)
        let space: CGColorSpace
        if let cs = image.colorSpace, cs.model == .rgb {
            space = cs
        } else {
            space = CGColorSpace(name: CGColorSpace.sRGB)!
        }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
