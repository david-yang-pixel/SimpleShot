import AppKit
import ApplicationServices
import Carbon.HIToolbox
import NaturalLanguage

// MARK: - 读取其他应用中选中的文字

enum SelectedTextReader {
    private static var enabledAXApps: Set<pid_t> = []

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 弹出系统的“辅助功能”授权提示
    static func requestTrust() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 先用辅助功能接口读取；应用不支持时，再模拟 ⌘C 读取并恢复剪贴板
    @MainActor
    static func read(from app: NSRunningApplication) async -> String? {
        switch readViaAccessibility(app: app) {
        case .text(let text):
            return text
        case .empty:
            return nil
        case .unsupported:
            // 访达里拖动是在选文件，不要模拟 ⌘C
            if app.bundleIdentifier == "com.apple.finder" { return nil }
            return await readViaCopy()
        }
    }

    private enum AXResult {
        case text(String), empty, unsupported
    }

    private static func readViaAccessibility(app: NSRunningApplication) -> AXResult {
        let pid = app.processIdentifier
        // Chrome / Electron 等应用需要显式打开辅助功能树
        if !enabledAXApps.contains(pid) {
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            enabledAXApps.insert(pid)
        }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .unsupported }
        let element = focused as! AXUIElement
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
        guard error == .success, let text = value as? String else { return .unsupported }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .text(text)
    }

    /// 模拟 ⌘C 读取选中文字，读完恢复原来的剪贴板内容
    @MainActor
    private static func readViaCopy() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        }
        let before = pasteboard.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        // 最多等 0.3 秒看剪贴板有没有变化
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if pasteboard.changeCount != before { break }
        }
        guard pasteboard.changeCount != before else { return nil }

        let types = pasteboard.types ?? []
        let text = types.contains(.fileURL) ? nil : pasteboard.string(forType: .string)

        // 恢复剪贴板
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = saved.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
        return text
    }
}

// MARK: - 划词翻译：监听鼠标选中文字，选中外文时显示翻译图标

@MainActor
final class SelectionTranslator {
    static let shared = SelectionTranslator()

    private var monitors: [Any] = []
    private var downPoint: CGPoint = .zero
    private var iconPanel: SelectionIconPanel?
    private var popup: SelectionTranslatePanel?
    private var hideIconTask: Task<Void, Never>?

    var isRunning: Bool { !monitors.isEmpty }

    func applySetting() {
        if Settings.shared.selectionTranslateEnabled { start() } else { stop() }
    }

    func start() {
        guard monitors.isEmpty else { return }
        if !SelectedTextReader.isTrusted && !Settings.shared.accessibilityPromptShown {
            Settings.shared.accessibilityPromptShown = true
            askForAccessibility()
        }
        let mouse = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleMouse(event)
            }
        }
        let other = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .scrollWheel, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.hideIcon()
                if event.type == .keyDown && Int(event.keyCode) == kVK_Escape {
                    self?.popup?.close()
                }
            }
        }
        monitors = [mouse, other].compactMap { $0 }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        hideIcon()
    }

    private func askForAccessibility() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "划词翻译需要“辅助功能”权限"
        alert.informativeText = """
            用来读取你在其他应用中选中的文字。SimpleShot 只在你选中文字时读取选中的内容，不会记录键盘输入。

            接下来系统会弹出提示，请在 系统设置 › 隐私与安全性 › 辅助功能 中打开 SimpleShot。\
            不想用划词翻译，可以在 SimpleShot 设置里关掉。
            """
        alert.addButton(withTitle: "去授权")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            SelectedTextReader.requestTrust()
        }
    }

    // MARK: 鼠标事件（全局监听只会收到其他应用的事件）

    private func handleMouse(_ event: NSEvent) {
        let location = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            downPoint = location
            hideIcon()
            popup?.closeIfNotPinned()
        case .leftMouseUp:
            let dragged = hypot(location.x - downPoint.x, location.y - downPoint.y) > 6
            guard dragged || event.clickCount >= 2 else { return }
            guard SelectedTextReader.isTrusted,
                  let app = NSWorkspace.shared.frontmostApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in
                // 等目标应用更新好选区
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard let text = await SelectedTextReader.read(from: app),
                      SelectionTranslator.isForeign(text) else { return }
                self.showIcon(at: location, text: text)
            }
        default:
            break
        }
    }

    /// 只有选中的不是中文时才提供翻译
    static func isForeign(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 5000 else { return false }
        let scalars = trimmed.unicodeScalars
        let letters = scalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters > 0 else { return false } // 纯数字、符号不翻译
        // 有假名或韩文：日语 / 韩语
        if scalars.contains(where: { (0x3040...0x30FF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }) {
            return true
        }
        let han = scalars.filter { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }.count
        if Double(han) / Double(letters) > 0.3 { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        if let lang = recognizer.dominantLanguage, lang == .simplifiedChinese || lang == .traditionalChinese {
            return false
        }
        return true
    }

    // MARK: 图标与浮窗

    private func showIcon(at point: CGPoint, text: String) {
        hideIcon()
        let panel = SelectionIconPanel.make { [weak self] in
            guard let self else { return }
            // 以被点击的图标为基准定位浮窗
            let anchor = self.iconPanel?.frame ?? CGRect(origin: point, size: .zero)
            self.hideIcon()
            self.showPopup(text: text, anchor: anchor)
        }
        panel.show(near: point)
        iconPanel = panel
        hideIconTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { self?.hideIcon() }
        }
    }

    private func hideIcon() {
        hideIconTask?.cancel()
        hideIconTask = nil
        iconPanel?.orderOut(nil)
        iconPanel = nil
    }

    private func showPopup(text: String, anchor: CGRect) {
        popup?.close()
        let panel = SelectionTranslatePanel.make(source: text)
        panel.onClose = { [weak self, weak panel] in
            if self?.popup === panel { self?.popup = nil }
        }
        popup = panel
        panel.show(anchor: anchor)
    }
}

// MARK: - 选中文字后出现的小图标

/// 在非活动窗口上第一次点击就生效的按钮
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class SelectionIconPanel: NSPanel {
    private var onClick: (() -> Void)?

    static func make(onClick: @escaping () -> Void) -> SelectionIconPanel {
        let panel = SelectionIconPanel(contentRect: NSRect(x: 0, y: 0, width: 30, height: 30),
                                       styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
        panel.onClick = onClick
        panel.configure()
        return panel
    }

    private func configure() {
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let button = FirstMouseButton(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        button.image = NSImage(systemSymbolName: "translate", accessibilityDescription: "翻译")
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        button.contentTintColor = .white
        button.toolTip = "翻译选中的文字"
        button.target = self
        button.action = #selector(clicked)
        contentView = button
    }

    override var canBecomeKey: Bool { false }

    @objc private func clicked() { onClick?() }

    func show(near point: CGPoint) {
        var origin = CGPoint(x: point.x + 8, y: point.y - 8 - frame.height)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX), visible.maxX - frame.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - frame.height)
        }
        setFrameOrigin(origin)
        orderFrontRegardless()
    }
}

// MARK: - 划词翻译浮窗

final class SelectionTranslatePanel: NSPanel {
    var onClose: (() -> Void)?
    private var sourceText = ""
    private let sourceLabel = NSTextField(wrappingLabelWithString: "")
    private let directionLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let copyButton = NSButton(title: "复制译文", target: nil, action: nil)
    private var resultView: NSTextView!
    private var scrollView: NSScrollView!
    private var heightConstraint: NSLayoutConstraint!
    private var runner: TranslationRunner?
    private var translation = ""

    static func make(source: String) -> SelectionTranslatePanel {
        let panel = SelectionTranslatePanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.sourceText = source.trimmingCharacters(in: .whitespacesAndNewlines)
        panel.configure()
        return panel
    }

    private func configure() {
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = NSSize(width: 280, height: 140)
        buildUI()
    }

    private func buildUI() {
        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.blendingMode = .behindWindow
        contentView = background

        sourceLabel.stringValue = sourceText
        sourceLabel.font = .systemFont(ofSize: 12)
        sourceLabel.textColor = .secondaryLabelColor
        sourceLabel.maximumNumberOfLines = 3
        sourceLabel.lineBreakMode = .byTruncatingTail
        sourceLabel.preferredMaxLayoutWidth = 340
        sourceLabel.toolTip = sourceText

        directionLabel.font = .systemFont(ofSize: 11, weight: .medium)
        directionLabel.textColor = .tertiaryLabelColor

        scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        resultView = scrollView.documentView as? NSTextView
        resultView.drawsBackground = false
        resultView.isEditable = false
        resultView.isSelectable = true
        resultView.font = .systemFont(ofSize: 15)
        resultView.textContainerInset = NSSize(width: 0, height: 2)
        resultView.textContainer?.lineFragmentPadding = 0

        spinner.style = .spinning
        spinner.controlSize = .small
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.target = self
        copyButton.action = #selector(copyTranslation)
        copyButton.isEnabled = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [spinner, statusLabel, spacer, copyButton])
        bar.orientation = .horizontal
        bar.spacing = 6

        let column = NSStackView(views: [sourceLabel, directionLabel, scrollView, bar])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.setCustomSpacing(10, after: sourceLabel)
        column.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(column)
        heightConstraint = scrollView.heightAnchor.constraint(equalToConstant: 40)
        heightConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: background.topAnchor, constant: 30),
            column.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            column.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12),
            sourceLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: column.widthAnchor),
            bar.widthAnchor.constraint(equalTo: column.widthAnchor),
            heightConstraint,
        ])
    }

    /// true：浮窗在图标上方，高度变化时底边固定、向上长；false：在图标下方，顶边固定、向下长
    private var growsUpward = true

    /// 浮窗出现在被点击图标的右上角（左下角贴着图标右上角）；上方放不下就放到图标右下方
    func show(anchor: CGRect) {
        let gap: CGFloat = 4
        var origin = CGPoint(x: anchor.maxX + gap, y: anchor.maxY + gap)
        growsUpward = true
        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.y + frame.height > visible.maxY - 4 {
                origin.y = anchor.minY - gap - frame.height
                growsUpward = false
            }
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - frame.width - 4)
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - frame.height - 4)
        }
        setFrameOrigin(origin)
        orderFrontRegardless()
        startTranslation()
    }

    private func startTranslation() {
        guard let content = contentView else { return }
        let runner = TranslationRunner(hostView: content)
        self.runner = runner
        spinner.startAnimation(nil)
        let start = Date()
        runner.translate(sourceText, onStart: { [weak self] plan in
            self?.directionLabel.stringValue = plan.direction
            self?.statusLabel.stringValue = plan.busyText
        }, completion: { [weak self] result in
            guard let self else { return }
            self.spinner.stopAnimation(nil)
            self.spinner.isHidden = true
            switch result {
            case .success(let text):
                self.translation = text
                self.resultView.string = text
                self.copyButton.isEnabled = true
                self.statusLabel.stringValue = String(format: "用时 %.1f 秒 · Esc 关闭", Date().timeIntervalSince(start))
                self.fitHeight()
            case .failure(let error):
                self.statusLabel.stringValue = "翻译失败"
                self.resultView.string = error.localizedDescription
                self.resultView.textColor = .systemRed
                self.fitHeight()
            }
        })
    }

    /// 根据译文长度调整高度（最多 360 点，超出可滚动）
    private func fitHeight() {
        guard let layout = resultView.layoutManager, let container = resultView.textContainer else { return }
        layout.ensureLayout(for: container)
        let textHeight = ceil(layout.usedRect(for: container).height) + 6
        let newHeight = min(max(textHeight, 24), 360)
        let delta = newHeight - heightConstraint.constant
        heightConstraint.constant = newHeight
        var frame = self.frame
        frame.size.height += delta
        if !growsUpward {
            frame.origin.y -= delta // 在图标下方：保持顶部位置不变
        }
        if let visible = screen?.visibleFrame {
            if frame.maxY > visible.maxY - 4 { frame.origin.y = visible.maxY - 4 - frame.height }
            if frame.minY < visible.minY + 4 { frame.origin.y = visible.minY + 4 }
        }
        setFrame(frame, display: true, animate: false)
    }

    @objc private func copyTranslation() {
        guard !translation.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(translation, forType: .string)
        statusLabel.stringValue = "✓ 已复制"
    }

    /// 点击浮窗外部时关闭（鼠标在浮窗上时不关）
    func closeIfNotPinned() {
        if !frame.contains(NSEvent.mouseLocation) { close() }
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func close() {
        super.close()
        onClose?()
        onClose = nil
    }
}
