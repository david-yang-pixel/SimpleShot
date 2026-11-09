import AppKit
import OSLog

enum AppLog {
    /// 查看：log show --last 5m --predicate 'subsystem == "io.github.simpleshot.SimpleShot"' --info
    static let capture = Logger(subsystem: "io.github.simpleshot.SimpleShot", category: "capture")
}

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
