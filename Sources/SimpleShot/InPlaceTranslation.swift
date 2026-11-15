import AppKit

/// 截图原位翻译：把译文盖在原文所在的位置
struct TranslatedBlock {
    /// 视图坐标（点，原点在左下）
    let rect: CGRect
    let text: String
    let fontSize: CGFloat
    let background: NSColor
    let foreground: NSColor
}

/// 识别出的一段原文（若干相邻的行合并而成）
struct SourceBlock {
    let rect: CGRect
    let text: String
    let lineHeight: CGFloat
}

@MainActor
enum InPlaceTranslation {
    /// 把识别出的行转换到视图坐标，并把上下相邻、左边对齐、字号相近的行合并成段落
    static func blocks(from lines: [OCRLine], in selection: CGRect) -> [SourceBlock] {
        struct Line { let rect: CGRect; let text: String }
        let converted = lines.map { line in
            Line(rect: CGRect(x: selection.minX + line.box.minX * selection.width,
                              y: selection.minY + line.box.minY * selection.height,
                              width: line.box.width * selection.width,
                              height: line.box.height * selection.height),
                 text: line.text)
        }
        .sorted { $0.rect.maxY != $1.rect.maxY ? $0.rect.maxY > $1.rect.maxY : $0.rect.minX < $1.rect.minX }

        var groups: [[Line]] = []
        for line in converted {
            if let previous = groups.last?.last {
                let gap = previous.rect.minY - line.rect.maxY
                let ratio = line.rect.height / max(previous.rect.height, 1)
                let overlap = min(previous.rect.maxX, line.rect.maxX) - max(previous.rect.minX, line.rect.minX)
                let leftAligned = abs(previous.rect.minX - line.rect.minX) < previous.rect.height * 1.5
                if gap < previous.rect.height * 0.9, gap > -previous.rect.height * 0.4,
                   (0.7...1.45).contains(ratio), overlap > 0 || leftAligned {
                    groups[groups.count - 1].append(line)
                    continue
                }
            }
            groups.append([line])
        }

        return groups.map { group in
            let rect = group.dropFirst().reduce(group[0].rect) { $0.union($1.rect) }
            let heights = group.map(\.rect.height).sorted()
            return SourceBlock(rect: rect, text: join(group.map(\.text)), lineHeight: heights[heights.count / 2])
        }
    }

    /// 拼接同一段里的多行：中日韩文字直接相连，西文用空格；行尾连字符去掉
    private static func join(_ lines: [String]) -> String {
        var result = ""
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            if result.isEmpty { result = text; continue }
            if result.hasSuffix("-"), let first = text.first, first.isLowercase {
                result.removeLast()
                result += text
            } else if isCJK(result.last) || isCJK(text.first) {
                result += text
            } else {
                result += " " + text
            }
        }
        return result
    }

    private static func isCJK(_ c: Character?) -> Bool {
        guard let scalar = c?.unicodeScalars.first?.value else { return false }
        return (0x2E80...0x9FFF).contains(scalar) || (0xAC00...0xD7AF).contains(scalar) || (0xFF00...0xFFEF).contains(scalar)
    }

    /// 找一个能把译文放进原文区域的字号
    static func fittingFontSize(for text: String, in rect: CGRect, lineHeight: CGFloat) -> CGFloat {
        var size = max(9, min(lineHeight * 0.78, 40))
        while size > 8 {
            let height = attributed(text, size: size, color: .black)
                .boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                              options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            if height <= rect.height + lineHeight * 0.25 { break }
            size -= 0.5
        }
        return size
    }

    static func attributed(_ text: String, size: CGFloat, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 0
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .regular),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }

    /// 根据背景亮度选文字颜色
    static func foreground(for background: NSColor) -> NSColor {
        let c = background.usingColorSpace(.sRGB) ?? background
        let luminance = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return luminance > 0.55 ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 0.97, alpha: 1)
    }

    /// 绘制：先用背景色盖住原文，再写译文（屏幕显示和导出共用）
    static func draw(_ blocks: [TranslatedBlock], in ctx: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for block in blocks {
            block.background.setFill()
            NSBezierPath(roundedRect: block.rect.insetBy(dx: -3, dy: -2), xRadius: 3, yRadius: 3).fill()
            let text = attributed(block.text, size: block.fontSize, color: block.foreground)
            let textHeight = text.boundingRect(with: CGSize(width: block.rect.width, height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            // 垂直居中；放不下时从顶部开始
            let top = textHeight < block.rect.height ? block.rect.maxY - (block.rect.height - textHeight) / 2 : block.rect.maxY
            text.draw(in: CGRect(x: block.rect.minX, y: top - textHeight - 1,
                                 width: block.rect.width, height: textHeight + 2))
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
