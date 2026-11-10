import AppKit

/// 不激活应用也能成为键盘焦点的面板（像 Spotlight），并自己处理常用编辑快捷键
final class InputTranslatePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        var action: Selector?
        if flags == .command {
            switch key {
            case "v": action = #selector(NSText.paste(_:))
            case "c": action = #selector(NSText.copy(_:))
            case "x": action = #selector(NSText.cut(_:))
            case "a": action = #selector(NSText.selectAll(_:))
            case "z": action = Selector(("undo:"))
            case "w": orderOut(nil); return true
            default: break
            }
        } else if flags == [.command, .shift], key == "z" {
            action = Selector(("redo:"))
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return false
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

/// 输入翻译：快捷键呼出，输入文字后回车翻译
@MainActor
final class InputTranslateController: NSObject, NSTextViewDelegate {
    static let shared = InputTranslateController()

    private var panel: InputTranslatePanel!
    private var inputView: NSTextView!
    private var outputView: NSTextView!
    private let directionLabel = NSTextField(labelWithString: "译文")
    private let statusLabel = NSTextField(labelWithString: "回车翻译，⇧回车换行；点窗口外或按 Esc 关闭")
    private let spinner = NSProgressIndicator()
    private let copyButton = NSButton(title: "复制译文", target: nil, action: nil)
    private var runner: TranslationRunner?
    private var hasPositioned = false
    private var requestID = 0

    private override init() {
        super.init()
        buildPanel()
        installClickOutsideMonitors()
    }

    /// 在窗口外点击即关闭：其他应用里的点击用全局监听，SimpleShot 自己其他窗口里的点击用本地监听
    private func installClickOutsideMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.closeIfClickedOutside()
            }
        }
        NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                if event.window !== self?.panel { self?.closeIfClickedOutside() }
            }
            return event
        }
    }

    private func closeIfClickedOutside() {
        guard panel.isVisible, panel.attachedSheet == nil,
              !panel.frame.contains(NSEvent.mouseLocation) else { return }
        panel.orderOut(nil)
    }

    /// 快捷键：没显示就打开，正在显示就关闭
    func toggle() {
        if panel.isVisible && panel.isKeyWindow {
            panel.orderOut(nil)
        } else {
            show()
        }
    }

    func show() {
        if !hasPositioned {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                let size = panel.frame.size
                panel.setFrameOrigin(CGPoint(x: visible.midX - size.width / 2,
                                             y: visible.minY + visible.height * 0.62 - size.height / 2))
            }
            hasPositioned = true
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(inputView)
        inputView.selectAll(nil) // 保留上次内容，直接输入即可替换
    }

    // MARK: UI

    private func makeTextArea(editable: Bool) -> (NSScrollView, NSTextView) {
        let scroll = NSTextView.scrollableTextView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let textView = scroll.documentView as! NSTextView
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isEditable = editable
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 15)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        return (scroll, textView)
    }

    private func buildPanel() {
        panel = InputTranslatePanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.title = "输入翻译"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 360, height: 240)

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.blendingMode = .behindWindow
        panel.contentView = background

        let (inputScroll, input) = makeTextArea(editable: true)
        let (outputScroll, output) = makeTextArea(editable: false)
        inputView = input
        outputView = output
        inputView.delegate = self

        let inputBox = boxed(inputScroll)
        let outputBox = boxed(outputScroll)

        directionLabel.font = .systemFont(ofSize: 11, weight: .medium)
        directionLabel.textColor = .secondaryLabelColor

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copyTranslation)
        copyButton.keyEquivalent = "\r"
        copyButton.keyEquivalentModifierMask = [.command]
        copyButton.toolTip = "复制译文 (⌘↩)"
        copyButton.isEnabled = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [spinner, statusLabel, spacer, copyButton])
        bar.orientation = .horizontal
        bar.spacing = 8

        let column = NSStackView(views: [inputBox, directionLabel, outputBox, bar])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: background.topAnchor, constant: 34),
            column.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            column.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12),
            inputBox.widthAnchor.constraint(equalTo: column.widthAnchor),
            outputBox.widthAnchor.constraint(equalTo: column.widthAnchor),
            bar.widthAnchor.constraint(equalTo: column.widthAnchor),
            outputBox.heightAnchor.constraint(equalTo: inputBox.heightAnchor),
            inputBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 70),
        ])
        runner = TranslationRunner(hostView: background)
    }

    /// 给文本区加一个浅色圆角底
    private func boxed(_ scroll: NSScrollView) -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.6).cgColor
        box.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: box.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -4),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -4),
        ])
        return box
    }

    // MARK: 输入

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === inputView else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                translate()
            }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            panel.orderOut(nil)
            return true
        }
        return false
    }

    private func translate() {
        let text = inputView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let runner else { return }
        requestID += 1
        let id = requestID
        let start = Date()
        spinner.isHidden = false
        spinner.startAnimation(nil)
        copyButton.isEnabled = false
        outputView.textColor = .labelColor
        runner.translate(text, onStart: { [weak self] plan in
            self?.directionLabel.stringValue = "译文（\(plan.direction)）"
            self?.statusLabel.stringValue = plan.busyText
        }, completion: { [weak self] result in
            guard let self, id == self.requestID else { return } // 只显示最后一次请求的结果
            self.spinner.stopAnimation(nil)
            self.spinner.isHidden = true
            switch result {
            case .success(let translated):
                self.outputView.string = translated
                self.copyButton.isEnabled = true
                self.statusLabel.stringValue = String(format: "用时 %.1f 秒 · ⌘↩ 复制译文", Date().timeIntervalSince(start))
            case .failure(let error):
                self.outputView.string = error.localizedDescription
                self.outputView.textColor = .systemRed
                self.statusLabel.stringValue = "翻译失败"
            }
        })
    }

    @objc private func copyTranslation() {
        let text = outputView.string
        guard copyButton.isEnabled, !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        statusLabel.stringValue = "✓ 译文已复制到剪贴板"
    }
}
