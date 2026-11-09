import AppKit
import Vision

/// 使用系统 Vision 框架离线识别文字（简体中文模型同时支持英文）
enum TextRecognizer {
    /// 超过这个像素数的图片先缩小再识别（约 2400×1600），足够识别清晰的文字
    private static let maxPixels = 4_000_000

    static func recognize(_ image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = makeRequest()
            let input = downscaledIfNeeded(image)
            let handler = VNImageRequestHandler(cgImage: input, options: [:])
            try handler.perform([request])
            return TextRecognizer.layout(request.results ?? [])
        }.value
    }

    /// 预热：在后台跑一次极小的识别，让系统提前加载识别模型。
    /// 开始截图时调用，用户框选的这几秒里模型就加载好了。
    static func warmUp() {
        Task.detached(priority: .utility) {
            guard let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            guard let blank = ctx.makeImage() else { return }
            try? VNImageRequestHandler(cgImage: blank, options: [:]).perform([makeRequest()])
        }
    }

    private static func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate // 快速模式不支持中文
        request.usesLanguageCorrection = true
        let wanted = ["zh-Hans", "en-US"]
        if let supported = try? request.supportedRecognitionLanguages() {
            let languages = wanted.filter { supported.contains($0) }
            if !languages.isEmpty { request.recognitionLanguages = languages }
        }
        return request
    }

    private static func downscaledIfNeeded(_ image: CGImage) -> CGImage {
        let pixels = image.width * image.height
        guard pixels > maxPixels else { return image }
        let scale = (Double(maxPixels) / Double(pixels)).squareRoot()
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// 按阅读顺序拼接：从上到下分行，同一行内从左到右
    private static func layout(_ observations: [VNRecognizedTextObservation]) -> String {
        struct Item {
            let text: String
            let box: CGRect // 归一化坐标，原点在左下
        }
        let items = observations.compactMap { obs -> Item? in
            guard let text = obs.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            return Item(text: text, box: obs.boundingBox)
        }
        .sorted { $0.box.midY > $1.box.midY }

        var rows: [[Item]] = []
        for item in items {
            if let last = rows.last?.last,
               abs(last.box.midY - item.box.midY) < min(last.box.height, item.box.height) * 0.5 {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows
            .map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }
}

/// 显示识别结果的小窗口：可编辑、可部分复制、可一键复制全部
@MainActor
final class TextResultWindowController: NSWindowController, NSWindowDelegate {
    private static var openControllers: [TextResultWindowController] = []

    private var textView: NSTextView!
    private let statusLabel = NSTextField(labelWithString: "正在识别文字…")
    private let spinner = NSProgressIndicator()
    private let copyButton = NSButton(title: "复制全部", target: nil, action: nil)

    static func show(recognizing image: CGImage) {
        let controller = TextResultWindowController()
        openControllers.append(controller)
        controller.present()
        Task { @MainActor in
            let start = Date()
            do {
                let text = try await TextRecognizer.recognize(image)
                controller.showResult(text, seconds: Date().timeIntervalSince(start))
            } catch {
                controller.showError(error.localizedDescription)
            }
        }
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "提取文字"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 340, height: 220)
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let scroll = NSTextView.scrollableTextView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .bezelBorder
        textView = scroll.documentView as? NSTextView
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isEditable = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeWindow))
        closeButton.bezelStyle = .rounded
        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copyAll)
        copyButton.keyEquivalent = "\r"
        copyButton.keyEquivalentModifierMask = [.command]
        copyButton.toolTip = "复制全部 (⌘↩)"
        copyButton.isEnabled = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [spinner, statusLabel, spacer, closeButton, copyButton])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scroll)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    private func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func showResult(_ text: String, seconds: TimeInterval) {
        let elapsed = String(format: "用时 %.1f 秒", seconds)
        stopSpinner()
        textView.isEditable = true
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setStatus("没有识别到文字（\(elapsed)）")
            return
        }
        textView.string = text
        copyButton.isEnabled = true
        setStatus("识别到 \(text.count) 个字符，\(elapsed)。可直接修改，选中部分后 ⌘C 可只复制部分")
        window?.makeFirstResponder(textView)
    }

    private func showError(_ message: String) {
        stopSpinner()
        setStatus("识别失败：\(message)")
    }

    private func stopSpinner() {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.toolTip = text
    }

    @objc private func copyAll() {
        let text = textView.string
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        setStatus("✓ 已复制到剪贴板")
    }

    @objc private func closeWindow() {
        window?.performClose(nil)
    }

    func windowWillClose(_ notification: Notification) {
        TextResultWindowController.openControllers.removeAll { $0 === self }
    }
}
