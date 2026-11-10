import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var captureItem: NSMenuItem!
    private var inputTranslateItem: NSMenuItem!
    private var secureInputItem: NSMenuItem!
    private var secureInputSeparator: NSMenuItem!
    private let capture = CaptureController()
    private lazy var settingsController = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()

        HotKeyManager.shared.handlers[.capture] = { [weak self] in
            self?.capture.startCapture()
        }
        HotKeyManager.shared.handlers[.inputTranslate] = {
            InputTranslateController.shared.toggle()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(shortcutDidChange),
                                               name: .shortcutDidChange, object: nil)

        let shortcut = Settings.shared.shortcut
        let status = HotKeyManager.shared.register(shortcut)
        let inputShortcut = Settings.shared.inputTranslateShortcut
        let inputStatus = HotKeyManager.shared.register(inputShortcut, for: .inputTranslate)
        updateMenuShortcut()
        if status == noErr && inputStatus != noErr {
            settingsController.show(message: "输入翻译快捷键 \(inputShortcut.displayString) 已被占用或注册失败，请设置一个新的快捷键。",
                                    isError: true)
        }
        if status != noErr {
            let message = status == OSStatus(eventHotKeyExistsErr)
                ? "快捷键 \(shortcut.displayString) 已被其他应用占用，请设置一个新的快捷键。"
                : "快捷键 \(shortcut.displayString) 注册失败（错误码 \(status)），请尝试设置一个新的快捷键。"
            settingsController.show(message: message, isError: true)
        }

        Updater.shared.startAutomaticChecks()

        SecureInputMonitor.shared.onChange = { [weak self] blocker in
            self?.updateSecureInputState(blocker)
        }
        SecureInputMonitor.shared.start()

        SelectionTranslator.shared.applySetting()

        if !ScreenCapturer.hasPermission() {
            ScreenCapturer.requestPermission()
        }
    }

    // MARK: - Menus

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setStatusIcon(blocked: false)

        let menu = NSMenu()
        // 安全输入警告（平时隐藏）
        secureInputItem = NSMenuItem(title: "", action: #selector(showSecureInputHelp), keyEquivalent: "")
        secureInputItem.target = self
        secureInputItem.isHidden = true
        menu.addItem(secureInputItem)
        secureInputSeparator = NSMenuItem.separator()
        secureInputSeparator.isHidden = true
        menu.addItem(secureInputSeparator)
        captureItem = NSMenuItem(title: "截图", action: #selector(captureFromMenu), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)
        inputTranslateItem = NSMenuItem(title: "输入翻译", action: #selector(openInputTranslate), keyEquivalent: "")
        inputTranslateItem.target = self
        menu.addItem(inputTranslateItem)
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
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    private func updateMenuShortcut() {
        func apply(_ item: NSMenuItem, _ title: String, _ s: Shortcut) {
            item.title = title
            if let key = s.menuKeyEquivalent {
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = s.cocoaModifiers
            } else {
                item.keyEquivalent = ""
                item.title = "\(title)    \(s.displayString)"
            }
        }
        apply(captureItem, "截图", Settings.shared.shortcut)
        apply(inputTranslateItem, "输入翻译", Settings.shared.inputTranslateShortcut)
    }

    @objc private func openInputTranslate() {
        InputTranslateController.shared.show()
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

    // MARK: - 安全输入提醒

    private func setStatusIcon(blocked: Bool) {
        guard let button = statusItem.button else { return }
        let name = blocked ? "exclamationmark.triangle" : "camera.viewfinder"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "SimpleShot")
        image?.isTemplate = true
        button.image = image
    }

    private func updateSecureInputState(_ blocker: SecureInputBlocker?) {
        let blocked = blocker != nil
        setStatusIcon(blocked: blocked)
        secureInputItem.isHidden = !blocked
        secureInputSeparator.isHidden = !blocked
        if let blocker {
            let text = "⚠️ 快捷键暂不可用：\(blocker.name) 开启了安全输入"
            secureInputItem.title = text
            statusItem.button?.toolTip = text
        } else {
            statusItem.button?.toolTip = "SimpleShot"
        }
    }

    @objc private func showSecureInputHelp() {
        guard let blocker = SecureInputMonitor.shared.blocker else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(blocker.name) 开启了“安全输入”"
        alert.informativeText = """
            开启安全输入时，macOS 会屏蔽所有应用的全局快捷键（SimpleShot、微信截图等都会失灵）。\
            通常是该应用里有密码输入框正处于激活状态。

            解决办法：
            1. 切换到 \(blocker.name)，在页面空白处点一下让光标离开密码框，或关闭登录页面；
            2. 仍不行就退出 \(blocker.name) 并重新打开。

            安全输入释放后，这条提醒会自动消失。也可以先从菜单栏点「截图」使用。
            """
        let app = blocker.pid > 0 ? NSRunningApplication(processIdentifier: blocker.pid) : nil
        if app != nil {
            alert.addButton(withTitle: "切换到 \(blocker.name)")
        }
        alert.addButton(withTitle: "好")
        if alert.runModal() == .alertFirstButtonReturn, let app {
            app.activate(options: [])
        }
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
