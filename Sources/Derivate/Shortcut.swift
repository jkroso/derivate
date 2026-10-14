import AppKit
import Carbon.HIToolbox

/// A key with modifiers that opens the panel from any app.
struct Shortcut: Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags

    static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: [.control, .command])

    /// The shortcut a key press makes, if it has a modifier other than
    /// Shift: a shortcut of a letter alone would take that letter from
    /// every app.
    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard !modifiers.subtracting(.shift).isEmpty, Self.keyNames[UInt32(event.keyCode)] != nil else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Reads a shortcut written as "Ctrl+Cmd+P", as the settings keep it.
    init?(_ text: String) {
        var modifiers: NSEvent.ModifierFlags = []
        var key: UInt32?
        for part in text.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
            switch part {
            case "ctrl", "control": modifiers.insert(.control)
            case "alt", "option", "opt": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            case "cmd", "command", "cmdorctrl", "commandorcontrol", "super": modifiers.insert(.command)
            default: key = Self.keyNames.first { $0.value.lowercased() == part }?.key
            }
        }
        guard let key, !modifiers.isEmpty else { return nil }
        self.init(keyCode: key, modifiers: modifiers)
    }

    /// The shortcut as the settings keep it: "Ctrl+Cmd+P".
    var text: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.option) { parts.append("Alt") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.command) { parts.append("Cmd") }
        parts.append(Self.keyNames[keyCode] ?? "?")
        return parts.joined(separator: "+")
    }

    /// The shortcut as macOS shows it in menus: "⌃⌘P".
    var symbols: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        let name = Self.keyNames[keyCode] ?? "?"
        return s + (Self.keySymbols[name] ?? name)
    }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        if modifiers.contains(.option) { m |= UInt32(optionKey) }
        if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    /// The names of the keys of a US keyboard, by their key codes.
    private static let keyNames: [UInt32: String] = {
        var names: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
            kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
            kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
            kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
            kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Escape: "Escape",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
            kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
            kVK_UpArrow: "Up", kVK_DownArrow: "Down", kVK_LeftArrow: "Left", kVK_RightArrow: "Right",
        ]
        let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19]
        for (i, code) in fKeys.enumerated() {
            names[code] = "F\(i + 1)"
        }
        return Dictionary(uniqueKeysWithValues: names.map { (UInt32($0.key), $0.value) })
    }()

    private static let keySymbols = [
        "Space": "Space", "Return": "↩", "Tab": "⇥", "Escape": "⎋",
        "Up": "↑", "Down": "↓", "Left": "←", "Right": "→",
    ]
}

/// The shortcut registered with the system, which calls its action from
/// any app. It needs no permission: macOS gives the key to the app that
/// registered it.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    enum Failure: LocalizedError {
        case taken, failed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .taken: "Another app uses that shortcut."
            case .failed(let status): "macOS refused the shortcut (error \(status))."
            }
        }
    }

    /// Makes the shortcut open the panel, in place of the one before.
    /// nil removes it.
    func register(_ shortcut: Shortcut?) throws {
        unregister()
        guard let shortcut else { return }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let me = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(), { _, _, me in
                guard let me else { return noErr }
                // Carbon calls its handlers on the main thread.
                MainActor.assumeIsolated {
                    Unmanaged<HotKey>.fromOpaque(me).takeUnretainedValue().action()
                }
                return noErr
            }, 1, &type, me, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x5350_4252), id: 1) // "SPBR"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        switch status {
        case noErr: return
        case OSStatus(eventHotKeyExistsErr): throw Failure.taken
        default: throw Failure.failed(status)
        }
    }

    func unregister() {
        if let ref {
            UnregisterEventHotKey(ref)
        }
        ref = nil
    }
}
