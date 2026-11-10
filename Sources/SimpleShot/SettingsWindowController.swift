import AppKit
import Carbon.HIToolbox

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let recorder = ShortcutRecorder()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let loginCheckbox = NSButton(checkboxWithTitle: "开机时自动启动", target: nil, action: nil)
    private let updateCheckbox = NSButton(checkboxWithTitle: "自动检查更新", target: nil, action: nil)

    // 翻译引擎
    private let enginePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let kindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let baseURLField = NSTextField(string: "")
    private let modelField = NSTextField(string: "")
    private let apiKeyField = NSSecureTextField(string: "")
    private let testButton = NSButton(title: "测试", target: nil, action: nil)
    private let testResultLabel = NSTextField(wrappingLabelWithString: "")
    private var grid: NSGridView!
    private let aiRows = 5...10

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
        loginCheckbox.state = Settings.shared.launchAtLogin ? .on : .off
        updateCheckbox.state = Settings.shared.autoCheckUpdates ? .on : .off

        let s = Settings.shared
        enginePopup.selectItem(at: s.translationEngine == .ai ? 1 : 0)
        kindPopup.selectItem(at: AIProviderKind.allCases.firstIndex(of: s.aiKind) ?? 0)
        baseURLField.stringValue = s.aiBaseURL
        modelField.stringValue = s.aiModel
        apiKeyField.stringValue = KeychainStore.apiKey(forBaseURL: s.aiBaseURL)
        presetPopup.selectItem(at: 0)
        updateAIRowsVisibility()
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


        loginCheckbox.target = self
        loginCheckbox.action = #selector(toggleLaunchAtLogin)
        updateCheckbox.target = self
        updateCheckbox.action = #selector(toggleAutoUpdate)
        let checkNowButton = NSButton(title: "立即检查", target: self, action: #selector(checkUpdatesNow))
        checkNowButton.bezelStyle = .rounded

        // 翻译引擎
        enginePopup.addItems(withTitles: ["系统翻译（离线、免费）", "AI 大模型（自己配置）"])
        enginePopup.target = self
        enginePopup.action = #selector(engineChanged)
        presetPopup.addItem(withTitle: "选择服务自动填写…")
        presetPopup.addItems(withTitles: AIPreset.all.map(\.name))
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged)
        kindPopup.addItems(withTitles: AIProviderKind.allCases.map(\.title))
        kindPopup.target = self
        kindPopup.action = #selector(aiFieldsChanged)
        for field in [baseURLField, modelField, apiKeyField] as [NSTextField] {
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 290).isActive = true
        }
        baseURLField.placeholderString = "https://api.deepseek.com/v1"
        modelField.placeholderString = "deepseek-chat"
        apiKeyField.placeholderString = "sk-…（保存在钥匙串中）"
        testButton.bezelStyle = .rounded
        testButton.target = self
        testButton.action = #selector(testAI)
        testResultLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        testResultLabel.textColor = .secondaryLabelColor
        testResultLabel.preferredMaxLayoutWidth = 230
        testResultLabel.stringValue = "只会发送识别出的文字，不会上传截图"

        let usage = NSTextField(wrappingLabelWithString:
            "使用：悬停单击选窗口，桌面单击截全屏，拖动框选区域。\n截好后回车 / 双击即复制到剪贴板，Esc 取消，右键重选。")
        usage.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        usage.textColor = .secondaryLabelColor
        usage.preferredMaxLayoutWidth = 300

        let versionLabel = NSTextField(labelWithString: "SimpleShot \(AppInfo.versionString)")
        versionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        versionLabel.textColor = .tertiaryLabelColor

        func row(_ views: [NSView]) -> NSStackView {
            let s = NSStackView(views: views)
            s.orientation = .horizontal
            s.spacing = 8
            return s
        }

        grid = NSGridView(views: [
            [label("截图快捷键："), row([recorder, resetButton])],
            [NSGridCell.emptyContentView, statusLabel],
            [NSGridCell.emptyContentView, loginCheckbox],
            [NSGridCell.emptyContentView, row([updateCheckbox, checkNowButton])],
            [label("翻译引擎："), enginePopup],
            [label("快速填写："), presetPopup],
            [label("接口类型："), kindPopup],
            [label("接口地址："), baseURLField],
            [label("模型："), modelField],
            [label("API Key："), apiKeyField],
            [NSGridCell.emptyContentView, row([testButton, testResultLabel])],
            [NSGridCell.emptyContentView, usage],
            [NSGridCell.emptyContentView, versionLabel],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.row(at: 1).topPadding = -4
        grid.row(at: 4).topPadding = 10
        grid.row(at: 11).topPadding = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
    }

    // MARK: - 翻译引擎

    private func updateAIRowsVisibility() {
        let hidden = enginePopup.indexOfSelectedItem != 1
        for i in aiRows { grid?.row(at: i).isHidden = hidden }
        resizeToFit()
    }

    /// 根据内容调整窗口高度，保持窗口顶部位置不变
    private func resizeToFit() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let target = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        var frame = window.frame
        frame.origin.y += frame.height - target.height
        frame.size = target.size
        window.setFrame(frame, display: true, animate: false)
    }

    @objc private func engineChanged() {
        Settings.shared.translationEngine = enginePopup.indexOfSelectedItem == 1 ? .ai : .system
        updateAIRowsVisibility()
    }

    @objc private func presetChanged() {
        let index = presetPopup.indexOfSelectedItem - 1
        guard AIPreset.all.indices.contains(index) else { return }
        let preset = AIPreset.all[index]
        kindPopup.selectItem(at: AIProviderKind.allCases.firstIndex(of: preset.kind) ?? 0)
        baseURLField.stringValue = preset.baseURL
        modelField.stringValue = preset.model
        apiKeyField.stringValue = KeychainStore.apiKey(forBaseURL: preset.baseURL)
        apiKeyField.placeholderString = preset.needsKey ? "sk-…（保存在钥匙串中）" : "本机服务通常不需要"
        saveAIFields(saveKey: false)
        testResultLabel.textColor = .secondaryLabelColor
        testResultLabel.stringValue = preset.needsKey ? "填好 API Key 后点「测试」" : "确认本机服务已启动后点「测试」"
    }

    @objc private func aiFieldsChanged() {
        saveAIFields(saveKey: true)
    }

    private func saveAIFields(saveKey: Bool) {
        let s = Settings.shared
        s.aiKind = AIProviderKind.allCases[max(0, kindPopup.indexOfSelectedItem)]
        s.aiBaseURL = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        s.aiModel = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if saveKey {
            KeychainStore.setAPIKey(apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                    forBaseURL: s.aiBaseURL)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        // 地址改动时先只保存地址/模型，API Key 在结束编辑时再按新地址处理
        let field = obj.object as? NSTextField
        saveAIFields(saveKey: field === apiKeyField)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === baseURLField else { return }
        let stored = KeychainStore.apiKey(forBaseURL: Settings.shared.aiBaseURL)
        if !stored.isEmpty {
            apiKeyField.stringValue = stored // 这个服务之前保存过 Key
        } else {
            saveAIFields(saveKey: true)
        }
    }

    @objc private func testAI() {
        saveAIFields(saveKey: true)
        let config = Settings.shared.aiConfig
        testButton.isEnabled = false
        testResultLabel.textColor = .secondaryLabelColor
        testResultLabel.stringValue = "正在测试…"
        Task { @MainActor in
            do {
                let result = try await AITranslator.translate("Hello, world! This is a translation test.",
                                                              to: "简体中文", config: config)
                testResultLabel.textColor = .systemGreen
                testResultLabel.stringValue = "✓ 连接成功：\(result)"
            } catch {
                testResultLabel.textColor = .systemRed
                testResultLabel.stringValue = "✗ \(error.localizedDescription)"
            }
            testButton.isEnabled = true
        }
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

    @objc private func toggleLaunchAtLogin() {
        do {
            try Settings.shared.setLaunchAtLogin(loginCheckbox.state == .on)
        } catch {
            setStatus("设置开机启动失败：\(error.localizedDescription)", isError: true)
        }
        loginCheckbox.state = Settings.shared.launchAtLogin ? .on : .off
    }

    @objc private func toggleAutoUpdate() {
        Settings.shared.autoCheckUpdates = updateCheckbox.state == .on
    }

    @objc private func checkUpdatesNow() {
        Updater.shared.checkForUpdates()
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
            MainActor.assumeIsolated {
                guard let self else { return event }
                return self.handle(event)
            }
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
