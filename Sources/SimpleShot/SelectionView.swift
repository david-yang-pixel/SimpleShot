import AppKit
import Carbon.HIToolbox

enum CaptureAction {
    case copy, cancel
}

@MainActor
protocol SelectionViewDelegate: AnyObject {
    /// 某块屏幕开始框选/选中，其余屏幕应锁定
    func selectionViewDidBeginSelection(_ view: SelectionView)
    /// 回到选择状态（右键重选）
    func selectionViewDidReset(_ view: SelectionView)
    /// 结束截图
    func selectionView(_ view: SelectionView, finishWith action: CaptureAction, image: CGImage?, pointSize: CGSize)
}

/// 覆盖整块屏幕的交互视图：悬停高亮窗口、框选、调整选区、标注。
final class SelectionView: NSView, ToolbarViewDelegate, NSTextFieldDelegate {
    weak var delegate: SelectionViewDelegate?
    let shot: ScreenShot

    private enum Phase { case choosing, creating, selected }

    private struct Handle {
        let x: Int // -1 左, 0 中, 1 右
        let y: Int // -1 下, 0 中, 1 上
    }

    private enum DragMode {
        case none
        case pending(CGPoint)
        case creating(CGPoint)
        case moving(CGPoint, CGRect)
        case resizing(Handle, CGRect)
        case annotating
    }

    private var phase: Phase = .choosing
    private var dragMode: DragMode = .none
    private var hoverRect: CGRect?
    private var mousePoint: CGPoint?
    private var selection: CGRect = .zero

    private var annotations: [Annotation] = []
    private var currentAnnotation: Annotation?
    private var tool: AnnotationTool?
    private var toolbar: ToolbarView?
    private var textField: NSTextField?
    private var trackingArea: NSTrackingArea?

    private lazy var renderer = AnnotationRenderer(
        mosaicImage: AnnotationRenderer.pixelate(shot.image, block: max(8, Int(10 * pixelScale))),
        canvasBounds: bounds
    )

    /// 其他屏幕已经开始选区时，本屏锁定
    var isLocked = false {
        didSet {
            if isLocked { hoverRect = nil; mousePoint = nil }
            needsDisplay = true
        }
    }

    /// 每点对应的像素数
    private var pixelScale: CGFloat {
        CGFloat(shot.image.width) / max(bounds.width, 1)
    }

    init(shot: ScreenShot, frame: CGRect) {
        self.shot = shot
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited,
                                         .cursorUpdate, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    /// 截图窗口刚出现时，根据当前鼠标位置初始化高亮
    func primeHover(globalMouse g: CGPoint) {
        guard let w = window, w.frame.contains(g) else {
            mousePoint = nil
            hoverRect = nil
            needsDisplay = true
            return
        }
        let p = CGPoint(x: g.x - w.frame.minX, y: g.y - w.frame.minY)
        mousePoint = p
        hoverRect = windowRect(at: p)
        needsDisplay = true
    }

    // MARK: - Geometry

    private func windowRect(at p: CGPoint) -> CGRect {
        shot.windowRects.first(where: { $0.contains(p) }) ?? bounds
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    private func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// 对齐到物理像素，避免导出图片模糊
    private func snapped(_ r: CGRect) -> CGRect {
        let s = pixelScale
        let minX = (r.minX * s).rounded() / s, minY = (r.minY * s).rounded() / s
        let maxX = (r.maxX * s).rounded() / s, maxY = (r.maxY * s).rounded() / s
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 1 / s), height: max(maxY - minY, 1 / s))
    }

    private func hitHandle(_ p: CGPoint) -> Handle? {
        let r = selection
        let tol: CGFloat = 6
        let inX = p.x >= r.minX - tol && p.x <= r.maxX + tol
        let inY = p.y >= r.minY - tol && p.y <= r.maxY + tol
        var hx = 0, hy = 0
        if inY {
            if abs(p.x - r.minX) <= tol { hx = -1 } else if abs(p.x - r.maxX) <= tol { hx = 1 }
        }
        if inX {
            if abs(p.y - r.minY) <= tol { hy = -1 } else if abs(p.y - r.maxY) <= tol { hy = 1 }
        }
        return (hx == 0 && hy == 0) ? nil : Handle(x: hx, y: hy)
    }

    private func resized(_ r: CGRect, _ h: Handle, to p: CGPoint) -> CGRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        if h.x == -1 { minX = p.x } else if h.x == 1 { maxX = p.x }
        if h.y == -1 { minY = p.y } else if h.y == 1 { maxY = p.y }
        return rect(CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: maxY))
    }

    private func moved(_ r: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        var o = CGPoint(x: r.minX + dx, y: r.minY + dy)
        o.x = min(max(o.x, 0), bounds.width - r.width)
        o.y = min(max(o.y, 0), bounds.height - r.height)
        return CGRect(origin: o, size: r.size)
    }

    // MARK: - Mouse

    override func mouseEntered(with event: NSEvent) {
        if !isLocked { window?.makeKey() }
    }

    override func mouseExited(with event: NSEvent) {
        if phase == .choosing {
            mousePoint = nil
            hoverRect = nil
            needsDisplay = true
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isLocked else { return }
        let p = convert(event.locationInWindow, from: nil)
        mousePoint = p
        if phase == .choosing { hoverRect = windowRect(at: p) }
        cursor(at: p).set()
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    override func mouseDown(with event: NSEvent) {
        guard !isLocked else { return }
        let p = clamp(convert(event.locationInWindow, from: nil))
        commitTextField()

        switch phase {
        case .choosing:
            dragMode = .pending(p)
        case .creating:
            break
        case .selected:
            if let tool = tool {
                if selection.contains(p) { beginAnnotation(tool, at: p) }
                return
            }
            if event.clickCount == 2 && selection.contains(p) {
                finish(.copy)
                return
            }
            if let h = hitHandle(p) {
                dragMode = .resizing(h, selection)
            } else if selection.contains(p) {
                dragMode = .moving(p, selection)
                NSCursor.closedHand.set()
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isLocked else { return }
        let p = clamp(convert(event.locationInWindow, from: nil))
        mousePoint = p

        switch dragMode {
        case .pending(let start):
            if hypot(p.x - start.x, p.y - start.y) > 3 {
                dragMode = .creating(start)
                phase = .creating
                selection = rect(start, p)
                delegate?.selectionViewDidBeginSelection(self)
            }
        case .creating(let start):
            selection = rect(start, p)
        case .moving(let start, let orig):
            selection = moved(orig, dx: p.x - start.x, dy: p.y - start.y)
            layoutToolbar()
        case .resizing(let h, let orig):
            selection = resized(orig, h, to: p)
            layoutToolbar()
        case .annotating:
            guard let a = currentAnnotation else { break }
            switch a.tool {
            case .rect, .ellipse, .arrow:
                a.points = [a.points[0], p]
            case .pen, .mosaic:
                if let last = a.points.last, hypot(p.x - last.x, p.y - last.y) >= 1.5 {
                    a.points.append(p)
                }
            case .text:
                break
            }
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !isLocked else { return }
        switch dragMode {
        case .pending:
            // 单击：选中高亮的窗口（桌面则为整屏）
            selection = hoverRect ?? bounds
            enterSelected()
        case .creating:
            if selection.width < 4 || selection.height < 4 {
                selection = hoverRect ?? bounds
            }
            enterSelected()
        case .moving, .resizing:
            selection = snapped(selection)
            layoutToolbar()
        case .annotating:
            if let a = currentAnnotation, a.isMeaningful { annotations.append(a) }
            currentAnnotation = nil
        case .none:
            break
        }
        dragMode = .none
        cursor(at: convert(event.locationInWindow, from: nil)).set()
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !isLocked else { return }
        if phase == .selected {
            resetToChoosing(at: convert(event.locationInWindow, from: nil))
        } else {
            finish(.cancel)
        }
    }

    private func enterSelected() {
        phase = .selected
        selection = snapped(selection)
        delegate?.selectionViewDidBeginSelection(self)
        showToolbar()
        window?.makeKey()
        window?.makeFirstResponder(self)
    }

    private func resetToChoosing(at p: CGPoint) {
        discardTextField()
        phase = .choosing
        dragMode = .none
        annotations.removeAll()
        currentAnnotation = nil
        tool = nil
        toolbar?.removeFromSuperview()
        toolbar = nil
        selection = .zero
        mousePoint = p
        hoverRect = windowRect(at: p)
        delegate?.selectionViewDidReset(self)
        NSCursor.crosshair.set()
        needsDisplay = true
    }

    private func cursor(at p: CGPoint) -> NSCursor {
        if let tb = toolbar, tb.frame.contains(p) { return .arrow }
        switch phase {
        case .choosing, .creating:
            return .crosshair
        case .selected:
            if let tool = tool {
                guard selection.contains(p) else { return .arrow }
                return tool == .text ? .iBeam : .crosshair
            }
            if let h = hitHandle(p) {
                if h.y == 0 { return .resizeLeftRight }
                if h.x == 0 { return .resizeUpDown }
                return .crosshair
            }
            if selection.contains(p) {
                if case .moving = dragMode { return .closedHand }
                return .openHand
            }
            return .arrow
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let code = Int(event.keyCode)
        if code == kVK_Escape {
            finish(.cancel)
            return
        }
        guard !isLocked, phase == .selected else { return }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch code {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            finish(.copy)
        case kVK_LeftArrow:
            nudge(dx: -step, dy: 0)
        case kVK_RightArrow:
            nudge(dx: step, dy: 0)
        case kVK_UpArrow:
            nudge(dx: 0, dy: step)
        case kVK_DownArrow:
            nudge(dx: 0, dy: -step)
        default:
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, !isLocked, phase == .selected,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        else { return super.performKeyEquivalent(with: event) }
        switch Int(event.keyCode) {
        case kVK_ANSI_Z:
            undo()
            return true
        case kVK_ANSI_C:
            finish(.copy)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    private func nudge(dx: CGFloat, dy: CGFloat) {
        selection = snapped(moved(selection, dx: dx, dy: dy))
        layoutToolbar()
        needsDisplay = true
    }

    private func undo() {
        if textField != nil {
            discardTextField()
        } else if !annotations.isEmpty {
            annotations.removeLast()
        }
        needsDisplay = true
    }

    // MARK: - Annotation

    private func beginAnnotation(_ tool: AnnotationTool, at p: CGPoint) {
        let style = AnnotationStyle.shared
        if tool == .text {
            beginText(at: p)
            return
        }
        currentAnnotation = Annotation(tool: tool, color: style.color,
                                       size: tool.size(for: style.sizeIndex), points: [p])
        dragMode = .annotating
    }

    private func beginText(at p: CGPoint) {
        let style = AnnotationStyle.shared
        let field = NSTextField(string: "")
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        applyStyle(to: field, style: style)
        let height = field.fittingSize.height
        field.frame = CGRect(x: p.x, y: p.y - height / 2, width: 40, height: height)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
    }

    private func applyStyle(to field: NSTextField, style: AnnotationStyle) {
        field.font = Annotation.textFont(size: AnnotationTool.text.size(for: style.sizeIndex))
        field.textColor = style.color
        let oldTop = field.frame.maxY
        let height = field.fittingSize.height
        if field.superview != nil {
            field.frame = CGRect(x: field.frame.minX, y: oldTop - height,
                                 width: field.frame.width, height: height)
            resizeTextField(field)
        }
    }

    private func resizeTextField(_ field: NSTextField) {
        let width = field.attributedStringValue.size().width + AnnotationRenderer.textInset * 2 + 12
        field.frame.size.width = max(40, ceil(width))
    }

    func controlTextDidChange(_ obj: Notification) {
        if let field = textField { resizeTextField(field) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitTextField()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            discardTextField()
            return true
        }
        return false
    }

    private func commitTextField() {
        guard let field = textField else { return }
        textField = nil
        let text = field.stringValue
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let color = field.textColor, let font = field.font {
            let a = Annotation(tool: .text, color: color, size: font.pointSize, points: [field.frame.origin])
            a.text = text
            a.textRect = field.frame
            annotations.append(a)
        }
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func discardTextField() {
        guard let field = textField else { return }
        textField = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: - Toolbar

    private func showToolbar() {
        if toolbar == nil {
            let tb = ToolbarView()
            tb.delegate = self
            addSubview(tb)
            toolbar = tb
        }
        layoutToolbar()
    }

    private func layoutToolbar() {
        guard let tb = toolbar else { return }
        tb.layoutSubtreeIfNeeded()
        let size = tb.fittingSize
        var x = selection.maxX - size.width
        var y = selection.minY - size.height - 8
        if y < 4 {
            y = selection.maxY + 8
            if y + size.height > bounds.maxY - 4 { y = selection.minY + 8 }
        }
        x = min(max(x, 4), bounds.width - size.width - 4)
        tb.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    func toolbar(_ toolbar: ToolbarView, didSelect tool: AnnotationTool?) {
        commitTextField()
        self.tool = tool
        window?.makeFirstResponder(self)
    }

    func toolbarDidChangeStyle(_ toolbar: ToolbarView) {
        if let field = textField { applyStyle(to: field, style: AnnotationStyle.shared) }
    }

    func toolbarDidChangeSize(_ toolbar: ToolbarView) {
        layoutToolbar()
    }

    func toolbarUndo(_ toolbar: ToolbarView) { undo() }
    func toolbarCancel(_ toolbar: ToolbarView) { finish(.cancel) }
    func toolbarConfirm(_ toolbar: ToolbarView) { finish(.copy) }

    // MARK: - Finish & export

    private func finish(_ action: CaptureAction) {
        commitTextField()
        guard action != .cancel, phase == .selected else {
            delegate?.selectionView(self, finishWith: .cancel, image: nil, pointSize: .zero)
            return
        }
        let image = renderOutput()
        delegate?.selectionView(self, finishWith: image == nil ? .cancel : action,
                                image: image, pointSize: selection.size)
    }

    /// 按原始像素分辨率导出选区（含标注）
    private func renderOutput() -> CGImage? {
        let s = pixelScale
        let image = shot.image
        // CGImage 坐标原点在左上
        let pixelRect = CGRect(x: selection.minX * s,
                               y: (bounds.height - selection.maxY) * s,
                               width: selection.width * s,
                               height: selection.height * s)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !pixelRect.isNull, pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }

        if annotations.isEmpty { return image.cropping(to: pixelRect) }

        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: Int(pixelRect.width), height: Int(pixelRect.height),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image.cropping(to: pixelRect) }

        // 视图坐标（点，左下原点）→ 位图坐标（像素，左下原点）
        let originX = pixelRect.minX / s
        let originY = bounds.height - pixelRect.maxY / s
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -originX, y: -originY)
        ctx.interpolationQuality = .none
        ctx.draw(image, in: bounds)
        ctx.clip(to: selection)
        for a in annotations { renderer.draw(a, in: ctx) }
        return ctx.makeImage()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let accent = NSColor.controlAccentColor.cgColor

        let hole: CGRect?
        switch phase {
        case .choosing: hole = isLocked ? nil : hoverRect
        case .creating, .selected: hole = selection
        }

        // 标注（只在选区内显示）
        if phase == .selected {
            ctx.saveGState()
            ctx.clip(to: selection)
            for a in annotations { renderer.draw(a, in: ctx) }
            if let a = currentAnnotation { renderer.draw(a, in: ctx) }
            ctx.restoreGState()
        }

        // 选区外变暗
        ctx.setFillColor(NSColor(white: 0, alpha: 0.4).cgColor)
        if let h = hole {
            ctx.addRect(bounds)
            ctx.addRect(h)
            ctx.fillPath(using: .evenOdd)
        } else {
            ctx.fill(bounds)
        }

        guard let h = hole else { return }

        // 边框
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(phase == .choosing ? 2 : 1)
        ctx.stroke(h.insetBy(dx: phase == .choosing ? 1 : 0.5, dy: phase == .choosing ? 1 : 0.5))

        // 控制点
        if phase == .selected && tool == nil {
            for hx in [-1, 0, 1] {
                for hy in [-1, 0, 1] where !(hx == 0 && hy == 0) {
                    let x = hx == -1 ? h.minX : (hx == 0 ? h.midX : h.maxX)
                    let y = hy == -1 ? h.minY : (hy == 0 ? h.midY : h.maxY)
                    let dot = CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7)
                    ctx.setFillColor(NSColor.white.cgColor)
                    ctx.fillEllipse(in: dot)
                    ctx.setStrokeColor(accent)
                    ctx.setLineWidth(1.5)
                    ctx.strokeEllipse(in: dot)
                }
            }
        }

        drawSizeLabel(for: h)

        if phase != .selected, !isLocked, let p = mousePoint {
            drawMagnifier(at: p)
        }
    }

    private func drawSizeLabel(for r: CGRect) {
        let s = pixelScale
        let text = "\(Int((r.width * s).rounded())) × \(Int((r.height * s).rounded()))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let box = CGSize(width: size.width + 12, height: size.height + 6)
        var origin = CGPoint(x: r.minX, y: r.maxY + 4)
        if origin.y + box.height > bounds.maxY { origin.y = r.maxY - box.height - 4; origin.x = r.minX + 4 }
        origin.x = min(max(origin.x, 0), bounds.width - box.width)
        let boxRect = CGRect(origin: origin, size: box)
        NSColor(white: 0, alpha: 0.75).setFill()
        NSBezierPath(roundedRect: boxRect, xRadius: 4, yRadius: 4).fill()
        str.draw(at: CGPoint(x: boxRect.minX + 6, y: boxRect.minY + 3))
    }

    private func drawMagnifier(at p: CGPoint) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let image = shot.image
        let s = pixelScale
        let count = 15          // 放大区域边长（像素）
        let cell: CGFloat = 8   // 每个像素放大后的边长（点）
        let loupeSize = CGFloat(count) * cell
        let infoHeight: CGFloat = 38

        var origin = CGPoint(x: p.x + 20, y: p.y - 20 - loupeSize - infoHeight)
        if origin.x + loupeSize > bounds.maxX { origin.x = p.x - 20 - loupeSize }
        if origin.y < bounds.minY { origin.y = p.y + 20 }
        let loupe = CGRect(x: origin.x, y: origin.y + infoHeight, width: loupeSize, height: loupeSize)
        let info = CGRect(x: origin.x, y: origin.y, width: loupeSize, height: infoHeight)

        let px = Int(p.x * s), py = Int((bounds.height - p.y) * s)
        let half = count / 2
        let src = CGRect(x: px - half, y: py - half, width: count, height: count)
        let clipped = src.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))

        ctx.saveGState()
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(loupe)
        if !clipped.isNull, let crop = image.cropping(to: clipped) {
            let topOffset = (clipped.minY - src.minY) * cell
            let dest = CGRect(x: loupe.minX + (clipped.minX - src.minX) * cell,
                              y: loupe.maxY - topOffset - clipped.height * cell,
                              width: clipped.width * cell,
                              height: clipped.height * cell)
            ctx.interpolationQuality = .none
            ctx.draw(crop, in: dest)
        }
        // 十字线
        let accent = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
        ctx.setFillColor(accent)
        ctx.fill(CGRect(x: loupe.minX, y: loupe.minY + CGFloat(half) * cell, width: loupeSize, height: cell))
        ctx.fill(CGRect(x: loupe.minX + CGFloat(half) * cell, y: loupe.minY, width: cell, height: loupeSize))
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: loupe.minX + CGFloat(half) * cell, y: loupe.minY + CGFloat(half) * cell,
                          width: cell, height: cell))
        ctx.stroke(loupe.insetBy(dx: 0.5, dy: 0.5))
        ctx.restoreGState()

        // 坐标与颜色
        NSColor(white: 0, alpha: 0.8).setFill()
        NSBezierPath(rect: info).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white,
        ]
        let hex = pixelHex(x: px, y: py) ?? "-"
        NSAttributedString(string: "(\(px), \(py))\n\(hex)", attributes: attrs)
            .draw(in: info.insetBy(dx: 6, dy: 4))
    }

    private func pixelHex(x: Int, y: Int) -> String? {
        let image = shot.image
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let crop = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let ok = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1,
                                      bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard ok else { return nil }
        return String(format: "#%02X%02X%02X", pixel[0], pixel[1], pixel[2])
    }
}
