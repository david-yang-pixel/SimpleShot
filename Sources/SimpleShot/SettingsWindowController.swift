import AppKit
import Carbon.HIToolbox

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let recorder = ShortcutRecorder()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let directoryLabel = NSTextField(labelWithString: "")
    private let loginCheckbox = NSButton(checkboxWithTitle: "开机时自动启动", target: nil, action: nil)

    private static let hint = "点击按钮后按下新的组合键；按 Esc 取消录制。"

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 240),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "SimpleShot 设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(message: String? = nil, isError: Bool = false) {
        refresh()
        if let message { setStatus(message, isError: isError) } else { setStatus(Self.hint, isError: false) }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func refresh() {
        recorder.shortcut = Settings.shared.shortcut
        directoryLabel.stringValue = (Settings.shared.saveDirectory.path as NSString).abbreviatingWithTildeInPath
        directoryLabel.toolTip = Settings.shared.saveDirectory.path
        loginCheckbox.state = Settings.shared.launchAtLogin ? .on : .off
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        recorder.onRecordingChanged = { recording in
            if recording { HotKeyManager.shared.suspend() } else { HotKeyManager.shared.resume() }
        }
        recorder.onCapture = { [weak self] shortcut in self?.apply(shortcut) }

        let resetButton = NSButton(title: "恢复默认", target: self, action: #selector(resetShortcut))
        resetButton.bezelStyle = .rounded

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.preferredMaxLayoutWidth = 300

        directoryLabel.lineBreakMode = .byTruncatingMiddle
        directoryLabel.translatesAutoresizingMaskIntoConstraints = false
        directoryLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        directoryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let chooseButton = NSButton(title: "更改…", target: self, action: #selector(chooseDirectory))
        chooseButton.bezelStyle = .rounded

        loginCheckbox.target = self
        loginCheckbox.action = #selector(toggleLaunchAtLogin)

        let usage = NSTextField(wrappingLabelWithString:
            "使用：悬停单击选窗口，桌面单击截全屏，拖动框选区域。\n回车 / 双击复制，⌘S 保存，Esc 取消，右键重选。")
        usage.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        usage.textColor = .secondaryLabelColor
        usage.preferredMaxLayoutWidth = 300

        func row(_ views: [NSView]) -> NSStackView {
            let s = NSStackView(views: views)
            s.orientation = .horizontal
            s.spacing = 8
            return s
        }

        let grid = NSGridView(views: [
            [label("截图快捷键："), row([recorder, resetButton])],
            [NSGridCell.emptyContentView, statusLabel],
            [label("保存位置："), row([directoryLabel, chooseButton])],
            [NSGridCell.emptyContentView, loginCheckbox],
            [NSGridCell.emptyContentView, usage],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.row(at: 1).topPadding = -4
        grid.row(at: 4).topPadding = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        return l
    }

    private func setStatus(_ text: String, isError: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    // MARK: - Actions

    private func apply(_ shortcut: Shortcut) {
        switch HotKeyManager.shared.change(to: shortcut) {
        case .success:
            recorder.shortcut = shortcut
            setStatus("✓ 已设置为 \(shortcut.displayString)", isError: false)
        case .failure(let error):
            recorder.shortcut = Settings.shared.shortcut
            setStatus(error.message, isError: true)
        }
    }

    @objc private func resetShortcut() {
        recorder.stopRecording()
        apply(.defaultShortcut)
    }

    @objc private func chooseDirectory() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Settings.shared.saveDirectory
        panel.prompt = "选择"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Settings.shared.saveDirectory = url
            self?.refresh()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try Settings.shared.setLaunchAtLogin(loginCheckbox.state == .on)
        } catch {
            setStatus("设置开机启动失败：\(error.localizedDescription)", isError: true)
        }
        loginCheckbox.state = Settings.shared.launchAtLogin ? .on : .off
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        recorder.stopRecording()
    }

    func windowWillClose(_ notification: Notification) {
        recorder.stopRecording()
    }
}

/// 点击后录制一个快捷键
final class ShortcutRecorder: NSButton {
    var shortcut: Shortcut? { didSet { updateTitle() } }
    var onCapture: ((Shortcut) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?

    private var monitor: Any?
    private(set) var isRecording = false

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(toggleRecording)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 150).isActive = true
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        updateTitle()
        onRecordingChanged?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stopRecording() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        guard isRecording else { return }
        isRecording = false
        updateTitle()
        onRecordingChanged?(false)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.type == .flagsChanged {
            let symbols = Shortcut.modifierSymbols(flags)
            title = symbols.isEmpty ? "请按下快捷键…" : symbols + "…"
            return nil
        }
        let code = Int(event.keyCode)
        if flags.isEmpty && (code == kVK_Escape || code == kVK_Delete || code == kVK_ForwardDelete) {
            stopRecording()
            return nil
        }
        let captured = Shortcut(event: event)
        stopRecording()
        onCapture?(captured)
        return nil
    }

    private func updateTitle() {
        title = isRecording ? "请按下快捷键…" : (shortcut?.displayString ?? "未设置")
    }
}
