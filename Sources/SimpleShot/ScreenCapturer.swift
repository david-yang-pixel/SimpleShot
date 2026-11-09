import AppKit
import OSLog
import ScreenCaptureKit

/// 某块屏幕在按下快捷键瞬间的“冻结画面”。
struct ScreenShot {
    let screen: NSScreen
    /// 屏幕原始像素图像
    let image: CGImage
    /// 屏幕上可见窗口的矩形（屏幕本地坐标，单位：点，原点在左下角），按从前到后排序
    let windowRects: [CGRect]
}

@MainActor
enum ScreenCapturer {
    static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func captureAllScreens() async throws -> [ScreenShot] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = onScreenWindowRects(content: content)

        var shots: [ScreenShot] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int((filter.contentRect.width * scale).rounded())
            config.height = Int((filter.contentRect.height * scale).rounded())
            config.showsCursor = false
            config.captureResolution = .best

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

            let frame = screen.frame
            let local: [CGRect] = windows.compactMap { rect in
                let clipped = rect.intersection(frame)
                guard !clipped.isNull, clipped.width >= 10, clipped.height >= 10 else { return nil }
                return clipped.offsetBy(dx: -frame.minX, dy: -frame.minY)
            }
            shots.append(ScreenShot(screen: screen, image: image, windowRects: local))
        }
        return shots
    }

    private static let log = AppLog.capture

    /// 屏幕上的普通窗口、Dock、菜单栏等（全局 Cocoa 坐标），从前到后。
    /// 窗口位置来自 ScreenCaptureKit（新系统上旧的 CGWindowList 可能拿不到其他应用的窗口），
    /// CGWindowList 只用来辅助确定前后顺序和过滤透明窗口，拿不到也不影响。
    private static func onScreenWindowRects(content: SCShareableContent) -> [CGRect] {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let maxLayer = Int(CGWindowLevelForKey(.statusWindow))

        var rank: [CGWindowID: Int] = [:]
        var transparent: Set<CGWindowID> = []
        let cgList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] ?? []
        for (index, info) in cgList.enumerated() {
            guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            rank[number] = index
            if let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha < 0.01 {
                transparent.insert(number)
            }
        }

        let candidates = content.windows.enumerated().filter { _, w in
            w.isOnScreen
                && w.windowLayer >= 0 && w.windowLayer <= maxLayer
                && w.frame.width >= 20 && w.frame.height >= 20
                && w.owningApplication?.processID != myPID
                && !transparent.contains(w.windowID)
        }
        // 有 CGWindowList 的顺序就按它排（从前到后），否则保持 ScreenCaptureKit 的顺序
        let ordered = candidates.sorted { a, b in
            let ra = rank[a.element.windowID] ?? (Int.max / 2 + a.offset)
            let rb = rank[b.element.windowID] ?? (Int.max / 2 + b.offset)
            return ra < rb
        }

        log.info("windows: sc=\(content.windows.count, privacy: .public) cg=\(cgList.count, privacy: .public) candidates=\(ordered.count, privacy: .public)")

        // CG 坐标（左上原点）→ Cocoa 坐标（左下原点）
        func cocoaRect(_ f: CGRect) -> CGRect {
            CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
        }

        var result: [CGRect] = []
        for (_, w) in ordered {
            let rect = cocoaRect(w.frame)
            let app = w.owningApplication?.bundleIdentifier ?? w.owningApplication?.applicationName ?? "?"
            // 高于普通层级、又几乎铺满某块屏幕的窗口，通常是透明遮罩（桌面小工具、菜单栏工具等），跳过
            let coversScreen = NSScreen.screens.contains { screen in
                let overlap = rect.intersection(screen.frame)
                return !overlap.isNull && overlap.width * overlap.height >= screen.frame.width * screen.frame.height * 0.9
            }
            let skipped = w.windowLayer > 0 && coversScreen
            log.info("window \(skipped ? "SKIP" : "use ", privacy: .public) app=\(app, privacy: .public) layer=\(w.windowLayer, privacy: .public) rect=\(NSStringFromRect(rect), privacy: .public)")
            if !skipped { result.append(rect) }
        }
        return result
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
