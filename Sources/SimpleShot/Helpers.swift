import AppKit

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var versionString: String { "版本 \(version)（\(build)）" }
}

@MainActor
enum PermissionHelper {
    static func showScreenRecordingAlert() {
        // 让系统把本应用加入“屏幕录制”列表
        ScreenCapturer.requestPermission()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "需要“屏幕录制”权限"
        alert.informativeText = "请在 系统设置 › 隐私与安全性 › 屏幕与系统录音 中打开 SimpleShot，然后退出并重新打开 SimpleShot。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            openScreenRecordingSettings()
        }
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func showCaptureError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "截图失败"
        alert.informativeText = "\(error.localizedDescription)\n\n如果刚刚授予了屏幕录制权限，请退出并重新打开 SimpleShot。"
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "打开系统设置")
        if alert.runModal() == .alertSecondButtonReturn {
            openScreenRecordingSettings()
        }
    }
}

/// 屏幕下方短暂出现的提示
@MainActor
enum Toast {
    private static var panel: NSPanel?

    static func show(_ text: String) {
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: text)
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.sizeToFit()
        let size = CGSize(width: label.frame.width + 32, height: label.frame.height + 20)

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let origin = CGPoint(x: screen.frame.midX - size.width / 2,
                             y: screen.frame.minY + screen.frame.height * 0.15)
        let p = NSPanel(contentRect: CGRect(origin: origin, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .transient]

        let bg = NSView(frame: CGRect(origin: .zero, size: size))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(white: 0, alpha: 0.78).cgColor
        bg.layer?.cornerRadius = 10
        label.frame.origin = CGPoint(x: 16, y: 10)
        bg.addSubview(label)
        p.contentView = bg
        p.orderFrontRegardless()
        panel = p

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if panel === p {
                p.orderOut(nil)
                panel = nil
            }
        }
    }
}
