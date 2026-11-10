import AppKit
import Carbon.HIToolbox

extension Notification.Name {
    static let shortcutDidChange = Notification.Name("SimpleShotShortcutDidChange")
}

enum ShortcutError: Error {
    case needsModifier
    case commonAppShortcut(String)
    case systemShortcut(String)
    case occupied(String)
    case ownShortcut(String, String)
    case failed(OSStatus)

    var message: String {
        switch self {
        case .needsModifier:
            return "快捷键至少要包含 ⌘、⌥、⌃ 中的一个"
        case .commonAppShortcut(let s):
            return "\(s) 是应用里常用的快捷键（复制、保存等），容易冲突，请换一个组合"
        case .systemShortcut(let s):
            return "\(s) 已被系统快捷键占用（系统设置 › 键盘 › 键盘快捷键），请换一个组合"
        case .occupied(let s):
            return "\(s) 已被其他应用占用，请换一个组合"
        case .ownShortcut(let s, let other):
            return "\(s) 已用作 SimpleShot 的「\(other)」快捷键，请换一个组合"
        case .failed(let code):
            return "注册快捷键失败（错误码 \(code)）"
        }
    }
}

/// 全局快捷键对应的功能
enum HotKeyAction: UInt32, CaseIterable {
    case capture = 1
    case inputTranslate = 2

    var title: String {
        switch self {
        case .capture: return "截图"
        case .inputTranslate: return "输入翻译"
        }
    }
}

/// 通过 Carbon 注册全局快捷键（无需“辅助功能”权限）。
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()
    private static let signature = OSType(0x5353_6874) // 'SSht'

    /// 各快捷键被按下时的处理
    var handlers: [HotKeyAction: () -> Void] = [:]

    /// 兼容旧接口：截图快捷键
    var onTrigger: (() -> Void)? {
        get { handlers[.capture] }
        set { handlers[.capture] = newValue }
    }

    private var refs: [HotKeyAction: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?

    private init() {
        installHandler()
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &id)
            guard status == noErr, id.signature == OSType(0x5353_6874),
                  let action = HotKeyAction(rawValue: id.id) else {
                return OSStatus(eventNotHandledErr)
            }
            Task { @MainActor in HotKeyManager.shared.handlers[action]?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    /// 注册（替换）某个功能的快捷键
    @discardableResult
    func register(_ shortcut: Shortcut, for action: HotKeyAction = .capture) -> OSStatus {
        unregister(action)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: HotKeyManager.signature, id: action.rawValue)
        // 若该组合已被其他应用注册，系统返回 eventHotKeyExistsErr
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id,
                                         GetApplicationEventTarget(), OptionBits(0), &ref)
        if status == noErr, let ref { refs[action] = ref }
        return status
    }

    func isRegistered(_ action: HotKeyAction) -> Bool {
        refs[action] != nil
    }

    /// 录制新快捷键时临时停用全部快捷键，避免误触发
    func suspend() {
        for action in HotKeyAction.allCases { unregister(action) }
    }

    func resume() {
        for action in HotKeyAction.allCases where refs[action] == nil {
            register(Settings.shared.shortcut(for: action), for: action)
        }
    }

    private func unregister(_ action: HotKeyAction) {
        if let ref = refs[action] {
            UnregisterEventHotKey(ref)
            refs[action] = nil
        }
    }

    /// 校验并切换到新的快捷键；成功后写入设置。失败时恢复旧快捷键。
    func change(to new: Shortcut, for action: HotKeyAction = .capture) -> Result<Void, ShortcutError> {
        let name = new.displayString
        guard new.hasPrimaryModifier else { return .failure(.needsModifier) }
        if ShortcutConflicts.isCommonAppShortcut(new) { return .failure(.commonAppShortcut(name)) }
        if ShortcutConflicts.isSystemShortcut(new) { return .failure(.systemShortcut(name)) }
        for other in HotKeyAction.allCases where other != action {
            if Settings.shared.shortcut(for: other) == new {
                return .failure(.ownShortcut(name, other.title))
            }
        }

        let old = Settings.shared.shortcut(for: action)
        if new == old && refs[action] != nil { return .success(()) }

        let status = register(new, for: action)
        if status == noErr {
            Settings.shared.setShortcut(new, for: action)
            NotificationCenter.default.post(name: .shortcutDidChange, object: nil)
            return .success(())
        }
        register(old, for: action)
        if status == OSStatus(eventHotKeyExistsErr) {
            return .failure(.occupied(name))
        }
        return .failure(.failed(status))
    }
}

/// 冲突检测：系统快捷键 + 应用常用快捷键。
/// 其他应用注册的全局快捷键由 RegisterEventHotKey 的 exclusive 选项检测。
enum ShortcutConflicts {
    private static let commonCmdShiftKeys: Set<Int> = [
        kVK_ANSI_Z, kVK_ANSI_S, kVK_ANSI_N, kVK_ANSI_T, kVK_ANSI_G, kVK_ANSI_A, kVK_ANSI_D,
        kVK_ANSI_O, kVK_ANSI_F, kVK_ANSI_K, kVK_ANSI_P, kVK_ANSI_R, kVK_ANSI_L, kVK_ANSI_U,
        kVK_ANSI_H, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket,
        kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6,
    ]

    static func isCommonAppShortcut(_ s: Shortcut) -> Bool {
        let m = s.modifiers & Shortcut.modifierMask
        if m == UInt32(cmdKey) { return true } // ⌘+单键 基本都被应用菜单使用
        if m == UInt32(cmdKey | shiftKey) && commonCmdShiftKeys.contains(Int(s.keyCode)) { return true }
        return false
    }

    /// 读取“系统设置 › 键盘快捷键”中已启用的系统快捷键
    static func isSystemShortcut(_ s: Shortcut) -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let array = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return false }
        for item in array {
            let enabled = (item["kHISymbolicHotKeyEnabled"] as? NSNumber)?.boolValue ?? false
            guard enabled,
                  let code = (item["kHISymbolicHotKeyCode"] as? NSNumber)?.intValue,
                  let mods = (item["kHISymbolicHotKeyModifiers"] as? NSNumber)?.uint32Value
            else { continue }
            if code == Int(s.keyCode) && (mods & Shortcut.modifierMask) == s.modifiers {
                return true
            }
        }
        return false
    }
}
