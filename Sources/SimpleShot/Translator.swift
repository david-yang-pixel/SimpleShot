import AppKit
import NaturalLanguage
import SwiftUI
import Translation

/// 自动判断翻译方向：中文 → 英文，其他语言 → 简体中文
enum TranslationDirection {
    static func decide(for text: String) -> (source: Locale.Language?, target: Locale.Language) {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let chinese = Locale.Language(identifier: "zh-Hans")
        let english = Locale.Language(identifier: "en")
        guard let detected = recognizer.dominantLanguage, detected != .undetermined else {
            return (nil, chinese) // 识别不出来就让系统自动检测，翻成中文
        }
        if detected == .simplifiedChinese || detected == .traditionalChinese {
            return (Locale.Language(identifier: detected.rawValue), english)
        }
        return (Locale.Language(identifier: detected.rawValue), chinese)
    }

    /// 语言的中文名，例如“英语”“简体中文”
    static func displayName(_ language: Locale.Language?) -> String {
        guard let language else { return "自动检测" }
        let zh = Locale(identifier: "zh-Hans")
        if let script = language.script?.identifier, language.languageCode?.identifier == "zh" {
            return script == "Hant" ? "繁体中文" : "简体中文"
        }
        if let code = language.languageCode?.identifier, let name = zh.localizedString(forLanguageCode: code) {
            return name
        }
        return language.maximalIdentifier
    }
}

// MARK: - 系统翻译（Translation 框架只能通过 SwiftUI 的 translationTask 获取会话）

@available(macOS 15.0, *)
@MainActor
final class TranslationModel: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    private var pendingText = ""
    private var completion: ((Result<String, Error>) -> Void)?

    func translate(_ text: String, from source: Locale.Language?, to target: Locale.Language,
                   completion: @escaping (Result<String, Error>) -> Void) {
        pendingText = text
        self.completion = completion
        if var config = configuration, config.source == source, config.target == target {
            config.invalidate() // 同样的语言对：让 translationTask 再执行一次
            configuration = config
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    func run(with session: TranslationSession) async {
        guard let completion, !pendingText.isEmpty else { return }
        self.completion = nil
        do {
            let response = try await session.translate(pendingText)
            completion(.success(response.targetText))
        } catch {
            completion(.failure(error))
        }
    }
}

@available(macOS 15.0, *)
struct TranslationHost: View {
    @ObservedObject var model: TranslationModel

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(model.configuration) { session in
                await model.run(with: session)
            }
    }
}

// MARK: - 翻译结果窗口

/// 上半部分原文（可编辑后重新翻译），下半部分译文
@MainActor
final class TranslateWindowController: NSWindowController, NSWindowDelegate {
    private static var openControllers: [TranslateWindowController] = []

    private var sourceView: NSTextView!
    private var targetView: NSTextView!
    private let directionLabel = NSTextField(labelWithString: "译文")
    private let statusLabel = NSTextField(labelWithString: "正在识别文字…")
    private let spinner = NSProgressIndicator()
    private let copyButton = NSButton(title: "复制译文", target: nil, action: nil)
    private let retranslateButton = NSButton(title: "重新翻译", target: nil, action: nil)
    private var model: AnyObject? // macOS 15+ 时为 TranslationModel

    static func show(recognizing image: CGImage) {
        let controller = TranslateWindowController()
        openControllers.append(controller)
        controller.present()
        Task { @MainActor in
            do {
                let text = try await TextRecognizer.recognize(image)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    controller.finish("没有识别到文字")
                    return
                }
                controller.sourceView.string = text
                controller.translate(text)
            } catch {
                controller.finish("识别失败：\(error.localizedDescription)")
            }
        }
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "翻译"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 320)
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: UI

    private func makeTextArea() -> (NSScrollView, NSTextView) {
        let scroll = NSTextView.scrollableTextView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .bezelBorder
        let textView = scroll.documentView as! NSTextView
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        return (scroll, textView)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let sourceLabel = NSTextField(labelWithString: "原文（识别有误可直接修改，然后点「重新翻译」）")
        sourceLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        sourceLabel.textColor = .secondaryLabelColor
        directionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        directionLabel.textColor = .secondaryLabelColor

        let (sourceScroll, source) = makeTextArea()
        let (targetScroll, target) = makeTextArea()
        sourceView = source
        targetView = target

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        retranslateButton.bezelStyle = .rounded
        retranslateButton.target = self
        retranslateButton.action = #selector(retranslate)
        retranslateButton.isEnabled = false
        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeWindow))
        closeButton.bezelStyle = .rounded
        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copyTranslation)
        copyButton.keyEquivalent = "\r"
        copyButton.keyEquivalentModifierMask = [.command]
        copyButton.toolTip = "复制译文 (⌘↩)"
        copyButton.isEnabled = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [spinner, statusLabel, spacer, retranslateButton, closeButton, copyButton])
        bar.orientation = .horizontal
        bar.spacing = 8

        let column = NSStackView(views: [sourceLabel, sourceScroll, directionLabel, targetScroll, bar])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.setCustomSpacing(12, after: sourceScroll)
        column.setCustomSpacing(10, after: targetScroll)
        column.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            sourceScroll.widthAnchor.constraint(equalTo: column.widthAnchor),
            targetScroll.widthAnchor.constraint(equalTo: column.widthAnchor),
            bar.widthAnchor.constraint(equalTo: column.widthAnchor),
            targetScroll.heightAnchor.constraint(equalTo: sourceScroll.heightAnchor),
            sourceScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
    }

    private func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: 翻译

    private func translate(_ text: String) {
        if Settings.shared.translationEngine == .ai {
            translateWithAI(text)
            return
        }
        guard #available(macOS 15.0, *) else {
            finish("翻译功能需要 macOS 15 或更高版本")
            return
        }
        let direction = TranslationDirection.decide(for: text)
        directionLabel.stringValue = "译文（\(TranslationDirection.displayName(direction.source)) → \(TranslationDirection.displayName(direction.target))）"
        setBusy("正在翻译…（某种语言首次使用时，系统会提示下载语言包）")
        let start = Date()

        Task { @MainActor in
            if let source = direction.source {
                let status = await LanguageAvailability().status(from: source, to: direction.target)
                if status == .unsupported {
                    self.finish("系统翻译暂不支持\(TranslationDirection.displayName(source))→\(TranslationDirection.displayName(direction.target))")
                    return
                }
            }
            self.translationModel().translate(text, from: direction.source, to: direction.target) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let translated):
                    self.targetView.string = translated
                    self.copyButton.isEnabled = true
                    self.finish(String(format: "翻译完成，用时 %.1f 秒", Date().timeIntervalSince(start)))
                case .failure(let error):
                    self.finish("翻译失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /// 用用户配置的 AI 模型翻译
    private func translateWithAI(_ text: String) {
        let config = Settings.shared.aiConfig
        let direction = TranslationDirection.decide(for: text)
        let targetName = TranslationDirection.displayName(direction.target)
        directionLabel.stringValue = "译文（\(TranslationDirection.displayName(direction.source)) → \(targetName)，\(config.displayName)）"

        let host = URL(string: config.baseURL)?.host ?? ""
        let isLocal = host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local")
        if config.apiKey.isEmpty && !isLocal {
            finish("请先在 设置 › 翻译引擎 里填写 API Key")
            return
        }

        setBusy("正在用 \(config.displayName) 翻译…")
        let start = Date()
        Task { @MainActor in
            do {
                let translated = try await AITranslator.translate(text, to: targetName, config: config)
                self.targetView.string = translated
                self.copyButton.isEnabled = true
                self.finish(String(format: "翻译完成，用时 %.1f 秒", Date().timeIntervalSince(start)))
            } catch {
                self.finish("翻译失败：\(error.localizedDescription)")
            }
        }
    }

    @available(macOS 15.0, *)
    private func translationModel() -> TranslationModel {
        if let existing = model as? TranslationModel { return existing }
        let created = TranslationModel()
        model = created
        let host = NSHostingView(rootView: TranslationHost(model: created))
        host.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        window?.contentView?.addSubview(host)
        return created
    }

    private func setBusy(_ text: String) {
        spinner.isHidden = false
        spinner.startAnimation(nil)
        retranslateButton.isEnabled = false
        setStatus(text)
    }

    private func finish(_ text: String) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        retranslateButton.isEnabled = !sourceView.string.isEmpty
        setStatus(text)
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.toolTip = text
    }

    // MARK: Actions

    @objc private func retranslate() {
        let text = sourceView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        translate(text)
    }

    @objc private func copyTranslation() {
        let text = targetView.string
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        setStatus("✓ 译文已复制到剪贴板")
    }

    @objc private func closeWindow() {
        window?.performClose(nil)
    }

    func windowWillClose(_ notification: Notification) {
        TranslateWindowController.openControllers.removeAll { $0 === self }
    }
}
