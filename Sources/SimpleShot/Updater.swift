import AppKit
import Security

struct ReleaseInfo {
    let version: String
    let notes: String
    let dmgURL: URL
    let pageURL: URL
}

enum UpdateError: LocalizedError {
    case network(String)
    case noAsset
    case badDownload
    case mountFailed
    case appNotFound
    case invalidPackage
    case signatureMismatch
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .network(let s): return "无法连接 GitHub（\(s)）"
        case .noAsset: return "新版本中没有找到安装包"
        case .badDownload: return "下载失败"
        case .mountFailed: return "无法打开下载的安装包"
        case .appNotFound: return "安装包中没有找到 SimpleShot.app"
        case .invalidPackage: return "安装包的版本或标识不正确"
        case .signatureMismatch: return "安装包签名校验失败（与当前版本的签名证书不一致）"
        case .installFailed(let s): return "安装失败：\(s)"
        }
    }
}

/// 基于 GitHub Releases 的应用内更新：检查 → 下载 DMG → 校验签名 → 替换并重启。
@MainActor
final class Updater {
    static let shared = Updater()

    private let repo = "david-yang-pixel/SimpleShot"
    private var isChecking = false
    private var isInstalling = false
    private var progressWindow: NSWindow?
    private var progressLabel: NSTextField?

    // MARK: - 检查

    /// 启动后 10 秒检查一次，之后每小时看一下距上次检查是否已超过 24 小时
    func startAutomaticChecks() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            while true {
                let settings = Settings.shared
                if settings.autoCheckUpdates,
                   Date().timeIntervalSince(settings.lastUpdateCheck) > 24 * 3600 {
                    await self.check(userInitiated: false)
                }
                try? await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
            }
        }
    }

    func checkForUpdates() {
        Task { @MainActor in await self.check(userInitiated: true) }
    }

    private func check(userInitiated: Bool) async {
        guard !isChecking, !isInstalling else { return }
        isChecking = true
        defer { isChecking = false }

        do {
            let release = try await fetchLatestRelease()
            Settings.shared.lastUpdateCheck = Date()
            guard Updater.compare(release.version, AppInfo.version) == .orderedDescending else {
                if userInitiated {
                    showAlert("已是最新版本", "当前版本 \(AppInfo.version) 已是最新。")
                }
                return
            }
            if !userInitiated && Settings.shared.skippedVersion == release.version { return }
            promptUpdate(release)
        } catch {
            if userInitiated {
                showAlert("检查更新失败", error.localizedDescription)
            }
        }
    }

    private func fetchLatestRelease() async throws -> ReleaseInfo {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw UpdateError.network("URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SimpleShot/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw UpdateError.network("HTTP \(code)") }

        struct APIRelease: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: String
            }
            let tag_name: String
            let body: String?
            let html_url: String
            let assets: [Asset]
        }
        let api = try JSONDecoder().decode(APIRelease.self, from: data)
        let version = api.tag_name.hasPrefix("v") ? String(api.tag_name.dropFirst()) : api.tag_name
        guard let asset = api.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }),
              let dmgURL = URL(string: asset.browser_download_url),
              let pageURL = URL(string: api.html_url) else { throw UpdateError.noAsset }
        return ReleaseInfo(version: version, notes: api.body ?? "", dmgURL: dmgURL, pageURL: pageURL)
    }

    /// 比较 "1.2.3" 形式的版本号
    nonisolated static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: - 提示

    private func promptUpdate(_ release: ReleaseInfo) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "发现新版本 SimpleShot \(release.version)"
        var notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 800 { notes = String(notes.prefix(800)) + "…" }
        alert.informativeText = "当前版本 \(AppInfo.version)。" + (notes.isEmpty ? "" : "\n\n\(notes)")
        alert.addButton(withTitle: "立即更新")
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "跳过此版本")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in await self.install(release) }
        case .alertThirdButtonReturn:
            Settings.shared.skippedVersion = release.version
        default:
            break
        }
    }

    // MARK: - 安装

    private func install(_ release: ReleaseInfo) async {
        guard !isInstalling else { return }
        let appURL = Bundle.main.bundleURL
        if let problem = installProblem(appURL: appURL) {
            offerManualDownload(release, reason: problem)
            return
        }

        isInstalling = true
        showProgress("正在下载 SimpleShot \(release.version)…")
        do {
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("SimpleShotUpdate-\(UUID().uuidString)")
            try fm.createDirectory(at: work, withIntermediateDirectories: true)

            let (tmp, response) = try await URLSession.shared.download(from: release.dmgURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.badDownload }
            let dmg = work.appendingPathComponent("update.dmg")
            try fm.moveItem(at: tmp, to: dmg)

            setProgress("正在校验安装包…")
            let staged = try await Task.detached { try Updater.extractApp(dmg: dmg, work: work) }.value
            try Updater.verify(staged: staged, expectedVersion: release.version)

            setProgress("正在安装，SimpleShot 将自动重新打开…")
            try Updater.launchInstaller(staged: staged, target: appURL, work: work)
            try? await Task.sleep(nanoseconds: 300_000_000)
            NSApp.terminate(nil)
        } catch {
            isInstalling = false
            hideProgress()
            offerManualDownload(release, reason: error.localizedDescription)
        }
    }

    /// 不能原地更新的情况
    private func installProblem(appURL: URL) -> String? {
        let path = appURL.path
        guard appURL.pathExtension == "app",
              Bundle.main.bundleIdentifier == "io.github.simpleshot.SimpleShot" else {
            return "当前不是以 SimpleShot.app 方式运行。"
        }
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            return "请先把 SimpleShot 拖到「应用程序」文件夹，再从那里打开。"
        }
        if !FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path) {
            return "没有权限替换 \(path)。"
        }
        if Updater.isAdHocSigned() {
            return "当前版本使用临时签名，无法自动更新。手动安装一次新版本后，以后即可在应用内直接更新。"
        }
        return nil
    }

    private nonisolated static func selfRequirement() -> SecRequirement? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, SecCSFlags(), &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    /// 临时签名的指定要求只包含 cdhash，每次构建都会变
    private nonisolated static func isAdHocSigned() -> Bool {
        guard let req = selfRequirement() else { return true }
        var text: CFString?
        guard SecRequirementCopyString(req, SecCSFlags(), &text) == errSecSuccess, let text else { return true }
        return (text as String).contains("cdhash")
    }

    private nonisolated static func extractApp(dmg: URL, work: URL) throws -> URL {
        let fm = FileManager.default
        let mount = work.appendingPathComponent("mnt")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        guard try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen",
                                           "-mountpoint", mount.path]) == 0 else {
            throw UpdateError.mountFailed
        }
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        let source = mount.appendingPathComponent("SimpleShot.app")
        guard fm.fileExists(atPath: source.path) else { throw UpdateError.appNotFound }
        let staged = work.appendingPathComponent("SimpleShot.app")
        guard try run("/usr/bin/ditto", [source.path, staged.path]) == 0 else {
            throw UpdateError.installFailed("复制安装包失败")
        }
        return staged
    }

    /// 校验：版本号、Bundle ID 正确，且签名满足当前应用的指定要求（同一证书签发）
    private nonisolated static func verify(staged: URL, expectedVersion: String) throws {
        guard let bundle = Bundle(url: staged),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == expectedVersion
        else { throw UpdateError.invalidPackage }

        guard let requirement = selfRequirement() else { throw UpdateError.signatureMismatch }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(staged as CFURL, SecCSFlags(), &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
        else { throw UpdateError.signatureMismatch }
    }

    /// 启动一个小脚本：等待本进程退出 → 替换应用 → 重新打开
    private nonisolated static func launchInstaller(staged: URL, target: URL, work: URL) throws {
        let script = """
        #!/bin/sh
        PID="$1"; SRC="$2"; DST="$3"; WORK="$4"
        i=0
        while kill -0 "$PID" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
        rm -rf "$DST.old"
        if mv "$DST" "$DST.old"; then
            if ditto "$SRC" "$DST"; then
                rm -rf "$DST.old"
            else
                rm -rf "$DST"; mv "$DST.old" "$DST"
            fi
        fi
        xattr -dr com.apple.quarantine "$DST" 2>/dev/null
        # 刷新 Launch Services 与图标缓存，否则可能继续显示旧图标
        touch "$DST"
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DST" 2>/dev/null
        killall Dock 2>/dev/null
        open "$DST"
        rm -rf "$WORK"
        """
        let scriptURL = work.appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier),
                       staged.path, target.path, work.path]
        try p.run()
    }

    @discardableResult
    private nonisolated static func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: - UI

    private func offerManualDownload(_ release: ReleaseInfo, reason: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "无法自动更新"
        alert.informativeText = "\(reason)\n\n可以前往下载页面手动安装 \(release.version)。"
        alert.addButton(withTitle: "打开下载页面")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.pageURL)
        }
    }

    private func showAlert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func showProgress(_ text: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "SimpleShot 更新"
        window.isReleasedWhenClosed = false

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: text)
        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            ])
        }
        progressWindow = window
        progressLabel = label
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func setProgress(_ text: String) {
        progressLabel?.stringValue = text
    }

    private func hideProgress() {
        progressWindow?.orderOut(nil)
        progressWindow = nil
        progressLabel = nil
    }
}
