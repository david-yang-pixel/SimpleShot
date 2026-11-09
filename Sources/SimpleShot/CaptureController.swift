import AppKit

/// 每块屏幕一个无边框的全屏窗口，底层显示冻结画面，上层是交互视图。
final class OverlayWindow: NSWindow {
    private(set) var selectionView: SelectionView!

    static func make(shot: ScreenShot) -> OverlayWindow {
        let frame = shot.screen.frame
        let w = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.setFrame(frame, display: false)
        w.level = .screenSaver
        w.isOpaque = true
        w.backgroundColor = .black
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        w.acceptsMouseMovedEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        let background = FrozenImageView(image: shot.image, frame: container.bounds)
        let selection = SelectionView(shot: shot, frame: container.bounds)
        container.addSubview(background)
        container.addSubview(selection)
        w.contentView = container
        w.selectionView = selection
        w.initialFirstResponder = selection
        return w
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 用 CALayer 直接显示截图，避免每次重绘整张大图
final class FrozenImageView: NSView {
    private let image: CGImage

    init(image: CGImage, frame: CGRect) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.contents = image
        layer?.contentsGravity = .resize
    }
}

@MainActor
final class CaptureController: SelectionViewDelegate {
    private var windows: [OverlayWindow] = []
    private var previousApp: NSRunningApplication?
    private var isBusy = false

    func startCapture() {
        guard !isBusy else { return }
        guard ScreenCapturer.hasPermission() else {
            PermissionHelper.showScreenRecordingAlert()
            return
        }
        isBusy = true
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front

        Task { @MainActor in
            do {
                let shots = try await ScreenCapturer.captureAllScreens()
                self.present(shots)
            } catch {
                self.isBusy = false
                PermissionHelper.showCaptureError(error)
            }
        }
    }

    private func present(_ shots: [ScreenShot]) {
        guard !shots.isEmpty else {
            isBusy = false
            return
        }
        for shot in shots {
            let w = OverlayWindow.make(shot: shot)
            w.selectionView.delegate = self
            windows.append(w)
            w.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)

        let mouse = NSEvent.mouseLocation
        let target = windows.first(where: { $0.frame.contains(mouse) }) ?? windows.first
        target?.makeKeyAndOrderFront(nil)
        if let target { target.makeFirstResponder(target.selectionView) }
        for w in windows { w.selectionView.primeHover(globalMouse: mouse) }
        NSCursor.crosshair.set()
    }

    private func close() {
        // 当前仍在窗口的事件处理栈中，延后释放窗口
        let old = windows
        windows.removeAll()
        for w in old { w.orderOut(nil) }
        DispatchQueue.main.async {
            for w in old { w.close() }
        }
        isBusy = false
        previousApp?.activate(options: [])
        previousApp = nil
    }

    // MARK: - SelectionViewDelegate

    func selectionViewDidBeginSelection(_ view: SelectionView) {
        for w in windows where w.selectionView !== view {
            w.selectionView.isLocked = true
        }
    }

    func selectionViewDidReset(_ view: SelectionView) {
        for w in windows { w.selectionView.isLocked = false }
    }

    func selectionView(_ view: SelectionView, finishWith action: CaptureAction, image: CGImage?, pointSize: CGSize) {
        close()
        guard let image else { return }
        switch action {
        case .copy:
            ImageExporter.copyToPasteboard(image, pointSize: pointSize)
        case .cancel:
            break
        }
    }
}
