import AppKit
import Carbon.HIToolbox
import IOKit

/// 占用“安全输入”的进程
struct SecureInputBlocker: Equatable {
    let pid: pid_t
    let name: String
}

/// 检测 macOS 的“安全输入”（Secure Event Input）。
/// 只要有任何应用开启它（通常是密码输入框处于激活状态），系统会屏蔽所有应用的全局快捷键。
@MainActor
final class SecureInputMonitor {
    static let shared = SecureInputMonitor()

    private(set) var blocker: SecureInputBlocker?
    var onChange: ((SecureInputBlocker?) -> Void)?
    private var started = false

    /// 每 2 秒检查一次（只读一次系统注册表，开销很小）
    func start() {
        guard !started else { return }
        started = true
        Task { @MainActor in
            while true {
                let current = SecureInputMonitor.currentBlocker()
                if current != self.blocker {
                    self.blocker = current
                    self.onChange?(current)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    static func currentBlocker() -> SecureInputBlocker? {
        let myPID = ProcessInfo.processInfo.processIdentifier
        if let pid = secureInputPID(), pid != myPID {
            return SecureInputBlocker(pid: pid, name: processName(pid))
        }
        // 拿不到具体进程，但系统报告安全输入已开启
        if IsSecureEventInputEnabled() {
            return SecureInputBlocker(pid: 0, name: "某个应用")
        }
        return nil
    }

    /// 读取 IORegistry 中 IOConsoleUsers 的 kCGSSessionSecureInputPID
    private static func secureInputPID() -> pid_t? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let value = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let users = value as? [[String: Any]] else { return nil }
        for user in users {
            if let pid = (user["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value, pid > 0 {
                return pid
            }
        }
        return nil
    }

    private static func processName(_ pid: pid_t) -> String {
        if let app = NSRunningApplication(processIdentifier: pid) {
            if let name = app.localizedName { return name }
            if let url = app.executableURL { return url.lastPathComponent }
        }
        return "进程 \(pid)"
    }
}
