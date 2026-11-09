import AppKit

@MainActor
protocol ToolbarViewDelegate: AnyObject {
    func toolbar(_ toolbar: ToolbarView, didSelect tool: AnnotationTool?)
    func toolbarDidChangeStyle(_ toolbar: ToolbarView)
    func toolbarDidChangeSize(_ toolbar: ToolbarView)
    func toolbarUndo(_ toolbar: ToolbarView)
    func toolbarSave(_ toolbar: ToolbarView)
    func toolbarCancel(_ toolbar: ToolbarView)
    func toolbarConfirm(_ toolbar: ToolbarView)
}

/// 选区下方的标注工具条：上排工具与操作，下排（选中工具后出现）尺寸与颜色。
final class ToolbarView: NSVisualEffectView {
    weak var delegate: ToolbarViewDelegate?
    private(set) var selectedTool: AnnotationTool?

    private var toolButtons: [AnnotationTool: NSButton] = [:]
    private let optionsRow = NSStackView()
    private var sizeDots: [DotView] = []
    private var colorDots: [DotView] = []

    init() {
        super.init(frame: .zero)
        material = .menu
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    // 吞掉工具条空白处的点击，避免穿透到下面的选区视图
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}

    // MARK: - UI

    private func buildUI() {
        let mainRow = NSStackView()
        mainRow.orientation = .horizontal
        mainRow.spacing = 2

        for tool in AnnotationTool.allCases {
            let b = makeButton(tool.symbolName, tool.title, #selector(toolTapped(_:)))
            b.tag = tool.rawValue
            toolButtons[tool] = b
            mainRow.addArrangedSubview(b)
        }
        mainRow.addArrangedSubview(makeSeparator())
        mainRow.addArrangedSubview(makeButton("arrow.uturn.backward", "撤销 (⌘Z)", #selector(undoTapped)))
        mainRow.addArrangedSubview(makeSeparator())
        mainRow.addArrangedSubview(makeButton("square.and.arrow.down", "保存到文件夹 (⌘S)", #selector(saveTapped)))
        let cancel = makeButton("xmark", "取消 (Esc)", #selector(cancelTapped))
        cancel.contentTintColor = .systemRed
        mainRow.addArrangedSubview(cancel)
        let confirm = makeButton("checkmark", "复制到剪贴板 (↩)", #selector(confirmTapped))
        confirm.contentTintColor = .systemGreen
        mainRow.addArrangedSubview(confirm)

        // 尺寸 + 颜色
        optionsRow.orientation = .horizontal
        optionsRow.spacing = 2
        let style = AnnotationStyle.shared
        for (i, d) in [4.0, 7.0, 10.0].enumerated() {
            let dot = DotView(kind: .size(CGFloat(d)))
            dot.isSelected = i == style.sizeIndex
            dot.onClick = { [weak self] in self?.selectSize(i) }
            sizeDots.append(dot)
            optionsRow.addArrangedSubview(dot)
        }
        optionsRow.addArrangedSubview(makeSeparator())
        for (i, c) in AnnotationStyle.palette.enumerated() {
            let dot = DotView(kind: .color(c))
            dot.isSelected = i == style.colorIndex
            dot.onClick = { [weak self] in self?.selectColor(i) }
            colorDots.append(dot)
            optionsRow.addArrangedSubview(dot)
        }
        optionsRow.isHidden = true

        let column = NSStackView(views: [mainRow, optionsRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    private func makeButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
        let b = NSButton(image: image, target: self, action: action)
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        b.contentTintColor = .labelColor
        b.toolTip = tip
        b.wantsLayer = true
        b.layer?.cornerRadius = 5
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 30).isActive = true
        b.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return b
    }

    private func makeSeparator() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 9).isActive = true
        v.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return v
    }

    // MARK: - Actions

    @objc private func toolTapped(_ sender: NSButton) {
        guard let tool = AnnotationTool(rawValue: sender.tag) else { return }
        setTool(selectedTool == tool ? nil : tool)
        delegate?.toolbar(self, didSelect: selectedTool)
    }

    func setTool(_ tool: AnnotationTool?) {
        selectedTool = tool
        for (t, b) in toolButtons {
            let on = t == tool
            b.contentTintColor = on ? .controlAccentColor : .labelColor
            b.layer?.backgroundColor = on ? NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor : nil
        }
        // 马赛克只需要尺寸，不需要颜色
        for dot in colorDots { dot.isHidden = tool == .mosaic }
        optionsRow.isHidden = tool == nil
        delegate?.toolbarDidChangeSize(self)
    }

    private func selectSize(_ index: Int) {
        AnnotationStyle.shared.sizeIndex = index
        for (i, d) in sizeDots.enumerated() { d.isSelected = i == index }
        delegate?.toolbarDidChangeStyle(self)
    }

    private func selectColor(_ index: Int) {
        AnnotationStyle.shared.colorIndex = index
        for (i, d) in colorDots.enumerated() { d.isSelected = i == index }
        delegate?.toolbarDidChangeStyle(self)
    }

    @objc private func undoTapped() { delegate?.toolbarUndo(self) }
    @objc private func saveTapped() { delegate?.toolbarSave(self) }
    @objc private func cancelTapped() { delegate?.toolbarCancel(self) }
    @objc private func confirmTapped() { delegate?.toolbarConfirm(self) }
}

/// 尺寸圆点 / 颜色圆点
final class DotView: NSView {
    enum Kind {
        case size(CGFloat)
        case color(NSColor)
    }

    let kind: Kind
    var isSelected = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        func circle(_ d: CGFloat) -> NSBezierPath {
            NSBezierPath(ovalIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
        }
        switch kind {
        case .size(let d):
            (isSelected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).setFill()
            circle(d).fill()
        case .color(let color):
            color.setFill()
            let dot = circle(14)
            dot.fill()
            NSColor.separatorColor.setStroke()
            dot.lineWidth = 1
            dot.stroke()
            if isSelected {
                let ring = circle(19)
                ring.lineWidth = 1.5
                NSColor.labelColor.setStroke()
                ring.stroke()
            }
        }
    }
}
