import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var captureItem: NSMenuItem!
    private let capture = CaptureController()
    private lazy var settingsController = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()

        HotKeyManager.shared.onTrigger = { [weak self] in
            self?.capture.startCapture()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(shortcutDidChange),
                                               name: .shortcutDidChange, object: nil)

        let shortcut = Settings.shared.shortcut
        let status = HotKeyManager.shared.register(shortcut)
        updateMenuShortcut()
        if status != noErr {
            let message = status == OSStatus(eventHotKeyExistsErr)
                ? "快捷键 \(shortcut.displayString) 已被其他应用占用，请设置一个新的快捷键。"
                : "快捷键 \(shortcut.displayString) 注册失败（错误码 \(status)），请尝试设置一个新的快捷键。"
            settingsController.show(message: message, isError: true)
        }

        Updater.shared.startAutomaticChecks()

        if !ScreenCapturer.hasPermission() {
            ScreenCapturer.requestPermission()
        }
    }

    // MARK: - Menus

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "SimpleShot")
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()
        captureItem = NSMenuItem(title: "截图", action: #selector(captureFromMenu), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let aboutItem = NSMenuItem(title: "关于 SimpleShot", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        let updateItem = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 SimpleShot", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
    }

    /// 主菜单（不显示，但让文本框支持 ⌘C/⌘V 等编辑快捷键，设置窗口支持 ⌘W）
    private func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "退出 SimpleShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    private func updateMenuShortcut() {
        let s = Settings.shared.shortcut
        captureItem.title = "截图"
        if let key = s.menuKeyEquivalent {
            captureItem.keyEquivalent = key
            captureItem.keyEquivalentModifierMask = s.cocoaModifiers
        } else {
            captureItem.keyEquivalent = ""
            captureItem.title = "截图    \(s.displayString)"
        }
    }

    // MARK: - Actions

    @objc private func captureFromMenu() {
        // 等菜单完全收起后再截图，避免把菜单截进去
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self.capture.startCapture()
        }
    }

    @objc private func openSettings() {
        settingsController.show()
    }

    @objc private func checkForUpdates() {
        Updater.shared.checkForUpdates()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func shortcutDidChange() {
        updateMenuShortcut()
    }
}
