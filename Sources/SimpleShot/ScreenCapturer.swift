import AppKit
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
        // 先记录窗口布局，再抓取画面，两者几乎同时
        let windows = onScreenWindowRects()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

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

    /// 屏幕上的普通窗口、Dock、菜单栏等（全局 Cocoa 坐标），从前到后。
    private static func onScreenWindowRects() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0

        return list.compactMap { info -> CGRect? in
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != myPID,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer >= 0, layer <= Int(CGWindowLevelForKey(.statusWindow)),
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            if let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha < 0.01 {
                return nil
            }
            guard b.width >= 20, b.height >= 20 else { return nil }
            // CG 坐标（左上原点）→ Cocoa 坐标（左下原点）
            return CGRect(x: b.minX, y: primaryHeight - b.maxY, width: b.width, height: b.height)
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
