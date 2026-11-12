import AppKit
import Carbon.HIToolbox
import Combine

/// A user-configurable key combination (works for both global hotkeys and in-panel keys).
struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt          // NSEvent.ModifierFlags raw value, masked to ⌘⇧⌥⌃
    var label: String            // printable key name, e.g. "D", "↩"

    static let mask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + label
    }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    func matches(_ e: NSEvent) -> Bool {
        e.keyCode == keyCode && e.modifierFlags.intersection(Shortcut.mask).rawValue == modifiers
    }

    static func from(_ e: NSEvent) -> Shortcut {
        let mods = e.modifierFlags.intersection(mask).rawValue
        return Shortcut(keyCode: e.keyCode, modifiers: mods, label: keyLabel(for: e))
    }

    private static func keyLabel(for e: NSEvent) -> String {
        switch Int(e.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: return (e.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}

enum Retention: Int, CaseIterable, Identifiable {
    case day = 1, week = 7, month = 30, quarter = 90, halfYear = 180, year = 365, forever = 0
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .day: return "1 天"
        case .week: return "1 周"
        case .month: return "1 个月"
        case .quarter: return "3 个月"
        case .halfYear: return "6 个月"
        case .year: return "1 年"
        case .forever: return "永久"
        }
    }
    /// nil = keep forever
    var cutoff: Date? {
        self == .forever ? nil : Calendar.current.date(byAdding: .day, value: -rawValue, to: Date())
    }
}

/// App-wide settings, persisted in UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()

    static let defaultOpen = Shortcut(keyCode: UInt16(kVK_ANSI_D), modifiers: NSEvent.ModifierFlags.command.rawValue, label: "D")
    /// In the panel: Return pastes the original, Shift+Return pastes as plain text.
    static let defaultPlain = Shortcut(keyCode: UInt16(kVK_Return), modifiers: NSEvent.ModifierFlags.shift.rawValue, label: "↩")
    /// "Paste as rich text": global (any app), and also acts on the selected card when the panel is open.
    static let defaultMarkdown = Shortcut(keyCode: UInt16(kVK_ANSI_V),
                                          modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, label: "V")

    @Published var openShortcut: Shortcut { didSet { save(openShortcut, "sc.open") } }
    @Published var plainShortcut: Shortcut { didSet { save(plainShortcut, "sc.plain") } }
    @Published var markdownShortcut: Shortcut { didSet { save(markdownShortcut, "sc.markdown.v2") } }
    @Published var retention: Retention {
        didSet { UserDefaults.standard.set(retention.rawValue, forKey: "retention.days") }
    }

    private init() {
        openShortcut = Settings.load("sc.open") ?? Settings.defaultOpen
        plainShortcut = Settings.load("sc.plain") ?? Settings.defaultPlain
        markdownShortcut = Settings.load("sc.markdown.v2") ?? Settings.defaultMarkdown
        let days = UserDefaults.standard.object(forKey: "retention.days") as? Int ?? Retention.month.rawValue
        retention = Retention(rawValue: days) ?? .month
    }

    func resetShortcuts() {
        openShortcut = Settings.defaultOpen
        plainShortcut = Settings.defaultPlain
        markdownShortcut = Settings.defaultMarkdown
    }

    private func save(_ s: Shortcut, _ key: String) {
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: key) }
    }
    private static func load(_ key: String) -> Shortcut? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
    }
}
