import AppKit
import AVFoundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

// MARK: - 录屏控制（开始 / 停止 / 状态）

@MainActor
final class RecordingController {
    static let shared = RecordingController()

    private(set) var isRecording = false
    /// 状态变化（是否在录、已录秒数），菜单栏图标据此显示计时
    var onStateChange: ((Bool, TimeInterval) -> Void)?

    private var session: AnyObject? // macOS 15+ 时为 RecordingSession
    private var borderWindow: NSWindow?
    private var hud: RecordingHUD?
    private var startDate = Date()
    private var timerTask: Task<Void, Never>?
    private var isStarting = false

    func start(screen: NSScreen, rect: CGRect, windowID: CGWindowID? = nil, systemAudio: Bool, microphone: Bool) {
        guard !isRecording, !isStarting else { return }
        guard #available(macOS 15.0, *) else {
            showAlert("录屏需要 macOS 15 或更高版本")
            return
        }
        isStarting = true
        Task { @MainActor in
            defer { self.isStarting = false }
            var useMicrophone = microphone
            if microphone {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                if !granted {
                    useMicrophone = false
                    self.showAlert("没有麦克风权限",
                                   "本次录屏不录麦克风。可在 系统设置 › 隐私与安全性 › 麦克风 中允许 SimpleShot。")
                }
            }
            do {
                let url = try RecordingController.makeOutputURL()
                let session = RecordingSession(url: url) { [weak self] result in
                    self?.didFinish(result)
                }
                let recordsWindow = try await session.start(screen: screen, rect: rect, windowID: windowID,
                                                            systemAudio: systemAudio, microphone: useMicrophone)
                self.session = session
                self.isRecording = true
                self.startDate = Date()
                // 录窗口时窗口可能被移动，不画固定的虚线框
                if !recordsWindow { self.showBorder(screen: screen, rect: rect) }
                self.showHUD(screen: screen, rect: recordsWindow ? nil : rect)
                self.startTimer()
            } catch {
                self.showAlert("无法开始录屏", error.localizedDescription)
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        timerTask?.cancel()
        timerTask = nil
        borderWindow?.orderOut(nil)
        borderWindow = nil
        hud?.orderOut(nil)
        hud = nil
        onStateChange?(false, 0)
        if #available(macOS 15.0, *), let session = session as? RecordingSession {
            Task { await session.stop() }
        }
    }

    private func didFinish(_ result: Result<URL, Error>) {
        if isRecording { stop() } // 录制意外中断（例如权限被撤销）
        session = nil
        switch result {
        case .success(let url):
            RecordingPreviewController.shared.show(url: url)
        case .failure(let error):
            showAlert("录屏失败", error.localizedDescription)
        }
    }

    private func startTimer() {
        onStateChange?(true, 0)
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.isRecording else { return }
                let elapsed = Date().timeIntervalSince(self.startDate)
                self.hud?.update(elapsed: elapsed)
                self.onStateChange?(true, elapsed)
            }
        }
    }

    /// 悬浮控制条：放在录制区域外面（下方，放不下就上方）；录窗口时放屏幕顶部中间
    private func showHUD(screen: NSScreen, rect: CGRect?) {
        let panel = RecordingHUD.make { [weak self] in self?.stop() }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        var origin = CGPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 12)
        if let rect {
            let global = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
            origin.x = global.midX - size.width / 2
            origin.y = global.minY - size.height - 12
            if origin.y < visible.minY + 4 {
                origin.y = global.maxY + 12
                if origin.y + size.height > visible.maxY - 4 {
                    // 区域几乎占满屏幕：放在区域内底部（SimpleShot 的窗口不会被录进去）
                    origin.y = global.minY + 16
                }
            }
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        hud = panel
    }

    /// 录制区域外围的红色虚线框（画在区域外面，且 SimpleShot 自己的窗口不会被录进去）
    private func showBorder(screen: NSScreen, rect: CGRect) {
        let inset: CGFloat = 4
        let frame = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY).insetBy(dx: -inset, dy: -inset)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = DashedBorderView(frame: NSRect(origin: .zero, size: frame.size))
        window.orderFrontRegardless()
        borderWindow = window
    }

    /// 录屏只写到系统临时目录，不保存到用户的文件夹；剪贴板换掉后自动删除
    private static func makeOutputURL() throws -> URL {
        let dir = TempRecordingStore.directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return dir.appendingPathComponent("录屏 \(formatter.string(from: Date())).mp4")
    }

    private func showAlert(_ title: String, _ text: String = "") {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

final class DashedBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 3, yRadius: 3)
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.systemRed.setStroke()
        path.stroke()
    }
}

// MARK: - 一次录制（ScreenCaptureKit 直接写 MP4，需要 macOS 15）

@available(macOS 15.0, *)
final class RecordingSession: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    private let url: URL
    private let completion: @MainActor (Result<URL, Error>) -> Void
    private var stream: SCStream?
    @MainActor private var delivered = false

    init(url: URL, completion: @escaping @MainActor (Result<URL, Error>) -> Void) {
        self.url = url
        self.completion = completion
    }

    /// 返回 true 表示按窗口录制
    @MainActor
    func start(screen: NSScreen, rect: CGRect, windowID: CGWindowID?,
               systemAudio: Bool, microphone: Bool) async throws -> Bool {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let id = screen.displayID,
              let display = content.displays.first(where: { $0.displayID == id }) else {
            throw NSError(domain: "SimpleShot", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到要录制的屏幕"])
        }
        let config = SCStreamConfiguration()
        let filter: SCContentFilter
        let recordsWindow: Bool
        if let windowID, let window = content.windows.first(where: { $0.windowID == windowID }) {
            // 单独录这个窗口：被其他窗口遮挡、被移动都能录到
            filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            config.width = max(16, Int((filter.contentRect.width * scale).rounded()) / 2 * 2)
            config.height = max(16, Int((filter.contentRect.height * scale).rounded()) / 2 * 2)
            recordsWindow = true
        } else {
            // 录屏幕上的固定区域；不录 SimpleShot 自己的窗口（虚线框、浮窗等）
            let myPID = ProcessInfo.processInfo.processIdentifier
            let me = content.applications.filter { $0.processID == myPID }
            filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            let scale = CGFloat(filter.pointPixelScale)
            // sourceRect 使用屏幕内坐标，原点在左上；H.264 要求偶数尺寸
            config.sourceRect = CGRect(x: rect.minX, y: screen.frame.height - rect.maxY,
                                       width: rect.width, height: rect.height)
            config.width = max(16, Int((rect.width * scale).rounded()) / 2 * 2)
            config.height = max(16, Int((rect.height * scale).rounded()) / 2 * 2)
            recordsWindow = false
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = true
        config.capturesAudio = systemAudio
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = microphone

        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        recording.outputFileType = .mp4
        recording.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: recording, delegate: self)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addRecordingOutput(output)
        try await stream.startCapture()
        self.stream = stream
        return recordsWindow
    }

    func stop() async {
        do {
            try await stream?.stopCapture()
        } catch {
            deliver(.failure(error))
        }
        stream = nil
    }

    // MARK: 回调

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        deliver(.success(url))
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        deliver(.failure(error))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        deliver(.failure(error))
    }

    private func deliver(_ result: Result<URL, Error>) {
        Task { @MainActor [weak self] in
            guard let self, !self.delivered else { return }
            self.delivered = true
            self.completion(result)
        }
    }
}

// MARK: - 录完后的预览小窗（右下角）

@MainActor
final class RecordingPreviewController {
    static let shared = RecordingPreviewController()

    private var panel: NSPanel?
    private var url: URL?
    private let statusLabel = NSTextField(labelWithString: "")
    private var autoCloseTask: Task<Void, Never>?
    private var gifButton: NSButton?

    func show(url: URL) {
        close()
        self.url = url
        copyFile(url)

        let width: CGFloat = 300
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 240),
                            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.blendingMode = .behindWindow
        panel.contentView = background

        let thumbnail = NSImageView()
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 6
        thumbnail.layer?.masksToBounds = true
        thumbnail.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "✓ 已复制到剪贴板（不保存到本地），可直接粘贴发送"
        statusLabel.lineBreakMode = .byTruncatingTail

        func button(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            b.imagePosition = .imageLeading
            return b
        }
        let copy = button("复制", "doc.on.doc", #selector(copyVideo))
        let gif = button("转 GIF", "photo.stack", #selector(makeGIF))
        gifButton = gif
        let discard = button("丢弃", "trash", #selector(discard))
        let buttons = NSStackView(views: [copy, gif, discard])
        buttons.orientation = .horizontal
        buttons.spacing = 6

        let column = NSStackView(views: [thumbnail, statusLabel, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: background.topAnchor, constant: 30),
            column.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            column.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12),
            thumbnail.widthAnchor.constraint(equalTo: column.widthAnchor),
            thumbnail.heightAnchor.constraint(equalToConstant: 150),
            statusLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])

        if let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: visible.maxX - width - 16, y: visible.minY + 16))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        scheduleAutoClose()

        // 缩略图和时长
        Task { @MainActor in
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 600, height: 600)
            if let (image, _) = try? await generator.image(at: .zero) {
                thumbnail.image = NSImage(cgImage: image, size: .zero)
            }
            if let duration = try? await asset.load(.duration), duration.seconds.isFinite {
                let s = Int(duration.seconds.rounded())
                panel.title = String(format: "录屏 %02d:%02d", s / 60, s % 60)
                panel.titleVisibility = .visible
            }
        }
    }

    private func scheduleAutoClose() {
        autoCloseTask?.cancel()
        autoCloseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self, let panel = self.panel else { return }
            if panel.frame.contains(NSEvent.mouseLocation) { self.scheduleAutoClose() } else { self.close() }
        }
    }

    var isShowing: Bool { panel != nil }

    private func close() {
        autoCloseTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
        TempRecordingStore.shared.cleanUpIfClipboardChanged()
    }

    private func copyFile(_ url: URL) {
        TempRecordingStore.shared.copyToClipboard(url)
    }

    @objc private func copyVideo() {
        guard let url else { return }
        copyFile(url)
        statusLabel.stringValue = "✓ 视频已复制到剪贴板"
        scheduleAutoClose()
    }

    @objc private func makeGIF() {
        guard let url else { return }
        gifButton?.isEnabled = false
        statusLabel.stringValue = "正在转换 GIF…"
        autoCloseTask?.cancel()
        Task { @MainActor in
            do {
                let gif = try await GIFMaker.make(from: url)
                self.copyFile(gif)
                self.url = gif
                self.statusLabel.stringValue = "✓ GIF 已生成并复制到剪贴板"
            } catch {
                self.statusLabel.stringValue = "GIF 转换失败：\(error.localizedDescription)"
            }
            self.gifButton?.isEnabled = true
            self.scheduleAutoClose()
        }
    }

    /// 丢弃：立即删除临时文件并清空剪贴板中的这段录屏
    @objc private func discard() {
        TempRecordingStore.shared.discardAll()
        url = nil
        close()
    }
}

// MARK: - MP4 转 GIF

enum GIFMaker {
    static func make(from url: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else {
                throw NSError(domain: "SimpleShot", code: 2, userInfo: [NSLocalizedDescriptionKey: "视频时长无效"])
            }
            // 每秒 12 帧；很长的视频降低帧率，最多约 600 帧
            let fps = min(12.0, 600.0 / duration)
            let count = max(1, Int(duration * fps))

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 800, height: 800)
            let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance

            let output = url.deletingPathExtension().appendingPathExtension("gif")
            try? FileManager.default.removeItem(at: output)
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString,
                                                                    count, nil) else {
                throw NSError(domain: "SimpleShot", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法创建 GIF 文件"])
            }
            let fileProperties = [kCGImagePropertyGIFDictionary as String:
                                    [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary
            CGImageDestinationSetProperties(destination, fileProperties)
            let frameProperties = [kCGImagePropertyGIFDictionary as String:
                                     [kCGImagePropertyGIFDelayTime as String: 1.0 / fps]] as CFDictionary
            for i in 0..<count {
                let time = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
                let (image, _) = try await generator.image(at: time)
                CGImageDestinationAddImage(destination, image, frameProperties)
            }
            guard CGImageDestinationFinalize(destination) else {
                throw NSError(domain: "SimpleShot", code: 4, userInfo: [NSLocalizedDescriptionKey: "GIF 写入失败"])
            }
            return output
        }.value
    }
}

// MARK: - 临时录屏文件：只为剪贴板存在

/// 录屏文件只放在系统临时目录。剪贴板内容被替换（且预览窗已关闭）后自动删除，
/// 启动时也会清掉上次残留的文件，不会在用户的文件夹里留下任何录屏。
@MainActor
final class TempRecordingStore {
    static let shared = TempRecordingStore()

    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SimpleShot-Recordings", isDirectory: true)
    }

    private var ownedChangeCount = -1
    private var watchTask: Task<Void, Never>?

    /// 启动时清理上次残留
    func cleanLeftovers() {
        try? FileManager.default.removeItem(at: TempRecordingStore.directory)
    }

    func copyToClipboard(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        ownedChangeCount = pb.changeCount
        startWatching()
    }

    /// 每 2 秒看一次剪贴板是否已被换掉
    private func startWatching() {
        guard watchTask == nil else { return }
        watchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                if self.cleanUpIfClipboardChanged() { return }
            }
        }
    }

    /// 剪贴板已不是我们的录屏、且没在录制和预览时，删除所有临时录屏
    @discardableResult
    func cleanUpIfClipboardChanged() -> Bool {
        guard NSPasteboard.general.changeCount != ownedChangeCount,
              !RecordingController.shared.isRecording,
              !RecordingPreviewController.shared.isShowing else { return false }
        deleteFiles()
        return true
    }

    func discardAll() {
        if NSPasteboard.general.changeCount == ownedChangeCount {
            NSPasteboard.general.clearContents()
        }
        deleteFiles()
    }

    private func deleteFiles() {
        watchTask?.cancel()
        watchTask = nil
        ownedChangeCount = -1
        let fm = FileManager.default
        let dir = TempRecordingStore.directory
        // 正在录制的文件不删
        guard !RecordingController.shared.isRecording,
              let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files { try? fm.removeItem(at: file) }
    }
}

// MARK: - 录制中的悬浮控制条：● 00:12 ｜ ■ 结束录制

final class RecordingHUD: NSPanel {
    private var onStop: (() -> Void)?
    private let timeLabel = NSTextField(labelWithString: "00:00")

    static func make(onStop: @escaping () -> Void) -> RecordingHUD {
        let panel = RecordingHUD(contentRect: NSRect(x: 0, y: 0, width: 196, height: 38),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.onStop = onStop
        panel.configure()
        return panel
    }

    override var canBecomeKey: Bool { false }

    private func configure() {
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        contentView = background

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        // 红点闪烁
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1
        blink.toValue = 0.25
        blink.duration = 0.8
        blink.autoreverses = true
        blink.repeatCount = .infinity
        dot.layer?.add(blink, forKey: "blink")

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        timeLabel.textColor = .labelColor

        let stop = FirstMouseButton(title: "结束录制", target: self, action: #selector(stopTapped))
        stop.bezelStyle = .rounded
        stop.controlSize = .small
        stop.bezelColor = .systemRed
        stop.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "结束录制")
        stop.imagePosition = .imageLeading
        stop.toolTip = "结束录制（也可以再按一次截图快捷键）"

        let row = NSStackView(views: [dot, timeLabel, stop])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -8),
        ])
    }

    func update(elapsed: TimeInterval) {
        let s = Int(elapsed)
        timeLabel.stringValue = String(format: "%02d:%02d", s / 60, s % 60)
    }

    @objc private func stopTapped() {
        onStop?()
    }
}
