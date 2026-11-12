import Foundation

/// A user-triggerable action contributed by a plugin (shown in the card context menu).
public struct ClipAction: Identifiable {
    public let id: String
    public let title: String
    public let symbol: String
    /// Return a new item to replace/insert, or nil for "nothing to do".
    public let run: (ClipItem) -> ClipItem?

    public init(id: String, title: String, symbol: String = "wand.and.stars", run: @escaping (ClipItem) -> ClipItem?) {
        self.id = id; self.title = title; self.symbol = symbol; self.run = run
    }
}

/// Plugin contract. Plugins live in their own modules and only depend on ClipCore.
public protocol ClipPlugin {
    /// Stable identifier, also used as the UserDefaults key prefix.
    var id: String { get }
    var name: String { get }
    var summary: String { get }
    /// Whether the plugin should be enabled the first time it is seen.
    var enabledByDefault: Bool { get }
    /// Whether the plugin offers an "auto-run on capture" mode (exposed as a toggle).
    var supportsAutoRun: Bool { get }

    /// Called for every newly captured item when the plugin is enabled and auto-run is on.
    /// Return a modified item, or nil to leave it untouched.
    func onCapture(_ item: ClipItem) -> ClipItem?
    /// Manual actions for an item (empty if not applicable).
    func actions(for item: ClipItem) -> [ClipAction]
}

public extension ClipPlugin {
    var enabledByDefault: Bool { true }
    var supportsAutoRun: Bool { false }
    func onCapture(_ item: ClipItem) -> ClipItem? { nil }
    func actions(for item: ClipItem) -> [ClipAction] { [] }
}

/// Registry + per-plugin enable/auto-run state. Plugins are pure add-ons: removing one
/// from `register` calls in the app shell removes the feature without touching the core.
public final class PluginManager: ObservableObject {
    public private(set) var plugins: [ClipPlugin] = []
    private let defaults = UserDefaults.standard

    public init() {}

    public func register(_ plugin: ClipPlugin) {
        guard !plugins.contains(where: { $0.id == plugin.id }) else { return }
        plugins.append(plugin)
        objectWillChange.send()
    }

    public func isEnabled(_ p: ClipPlugin) -> Bool {
        defaults.object(forKey: "plugin.\(p.id).enabled") as? Bool ?? p.enabledByDefault
    }
    public func setEnabled(_ p: ClipPlugin, _ on: Bool) {
        defaults.set(on, forKey: "plugin.\(p.id).enabled"); objectWillChange.send()
    }
    public func isAutoRun(_ p: ClipPlugin) -> Bool {
        // Auto-conversion is on for new installs; an explicit user choice of false
        // is still respected.
        defaults.object(forKey: "plugin.\(p.id).auto.v2") as? Bool ?? p.supportsAutoRun
    }
    public func setAutoRun(_ p: ClipPlugin, _ on: Bool) {
        defaults.set(on, forKey: "plugin.\(p.id).auto.v2"); objectWillChange.send()
    }

    /// Run the capture pipeline across enabled, auto-run plugins.
    public func processCapture(_ item: ClipItem) -> ClipItem {
        var cur = item
        for p in plugins where isEnabled(p) && p.supportsAutoRun && isAutoRun(p) {
            if let out = p.onCapture(cur) { cur = out }
        }
        return cur
    }

    public func actions(for item: ClipItem) -> [ClipAction] {
        plugins.filter(isEnabled).flatMap { $0.actions(for: item) }
    }
}
