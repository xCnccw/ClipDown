import AppKit
import SwiftUI
import Carbon.HIToolbox
import ClipCore
import MarkdownPlugin   // <- the only line (plus the register call below) coupling the app to this plugin

final class Panel: NSPanel {
    var onEscape: (() -> Void)?
    /// Return true when the event was consumed (configurable paste shortcuts live here).
    var keyHandler: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Catch Esc before any text field / field editor can swallow it.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 { onEscape?(); return }
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    /// AppKit normally nudges borderless windows out of the Dock / menu-bar area.
    /// Returning the rect untouched lets the panel sit flush with the bottom screen edge, over the Dock.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    var panel: Panel!
    var statusItem: NSStatusItem!
    var hotKeyRef: EventHotKeyRef?
    var richHotKeyRef: EventHotKeyRef?
    var pluginItems: [String: NSMenuItem] = [:]
    var hotKeyHandlerInstalled = false
    var openItem: NSMenuItem?
    var purgeTimer: Timer?
    var settingsWindow: NSWindow?
    private var settingsObserver: Any?

    func applicationDidFinishLaunching(_ n: Notification) {
        // ---- Plugin registration: add/remove plugins here ----
        state.plugins.register(MarkdownPlugin())
        // -------------------------------------------------------

        state.onDismiss = { [weak self] in self?.hidePanel() }
        setupPanel()
        setupStatusItem()
        registerHotKey()
        startPurgeTimer()
        // Debug aid: CLIPDOWN_SHOW=1 opens the panel shortly after launch.
        if ProcessInfo.processInfo.environment["CLIPDOWN_SHOW"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.showPanel() }
        }
        if ProcessInfo.processInfo.environment["CLIPDOWN_SETTINGS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.openSettings() }
        }
    }

    // MARK: Panel
    private let panelHeight: CGFloat = 333
    private var animating = false
    private var slideView: NSView!
    private var outsideClickMonitor: Any?

    func setupPanel() {
        // This panel must become the key window so ⌘V reaches ClipDown instead of
        // being handled by the previously active app or a field editor.
        panel = Panel(contentRect: .zero, styleMask: [.borderless],
                      backing: .buffered, defer: false)
        panel.onEscape = { [weak self] in
            guard let self else { return }
            if self.state.editingBoard != nil { self.state.cancelEdit() }
            else if self.state.searching { self.state.endSearch() }
            else { self.hidePanel() }
        }
        panel.keyHandler = { [weak self] event in self?.handlePanelKey(event) ?? false }
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // The surface below is animated as one unit, so the background leaves together
        // with the SwiftUI content instead of lingering behind it.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        // Set this last: isFloatingPanel above resets the level to floating (layer 3).
        // Level 24 (AppKit mainMenu) sits above the Dock (20), so the panel covers it.
        panel.level = .mainMenu

        // The window itself never moves: it is fixed at the final frame and the content
        // slides inside it via a Core Animation transform. This keeps the animation on the
        // GPU (no SwiftUI relayout per frame) and the window can never leave its own screen.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        let surface = SurfaceView()
        surface.layer?.masksToBounds = true
        surface.frame = container.bounds
        surface.autoresizingMask = [.width, .height]
        container.addSubview(surface)
        let host = NSHostingView(rootView: PanelView(state: state))
        host.frame = surface.bounds
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        surface.addSubview(host)
        slideView = surface
        panel.contentView = container
    }

    /// The panel always uses the primary screen, which is where the Dock lives.
    private func activeScreen() -> NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }

    private func slide(from: CGFloat, to: CGFloat, duration: CFTimeInterval,
                       timing: CAMediaTimingFunction, done: @escaping () -> Void) {
        guard let layer = slideView.layer else { done(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { done() } }
        let anim = CABasicAnimation(keyPath: "transform.translation.y")
        anim.fromValue = from
        anim.toValue = to
        anim.duration = duration
        anim.timingFunction = timing
        anim.fillMode = .both
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: "slide")
        CATransaction.commit()
    }

    func showPanel() {
        guard !animating, !panel.isVisible, let screen = activeScreen() else { return }
        state.previousApp = NSWorkspace.shared.frontmostApplication
        state.query = ""; state.selection = nil; state.previewing = false

        // Full screen width starting at the very bottom edge (covers the Dock).
        let full = screen.frame
        // Use the full screen frame so the panel occupies the Dock area. Its level is
        // one above the Dock, so the Dock cannot paint over the bottom of the panel.
        let target = NSRect(x: full.minX, y: full.minY, width: full.width, height: panelHeight)
        panel.setFrame(target, display: false)

        animating = true
        slideView.layer?.removeAllAnimations()
        slide(from: -panelHeight, to: 0, duration: 0.26,
              timing: CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)) { [weak self] in
            self?.slideView.layer?.removeAnimation(forKey: "slide")
            self?.animating = false
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        installOutsideClickMonitor()
    }

    /// Global monitors only see events destined for *other* apps, i.e. clicks outside our panel.
    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.hidePanel() }
        }
    }

    /// In-panel paste keys: Return pastes the original, Shift+Return pastes plain text.
    /// The plain-text and rich-text keys are user-configurable in Settings.
    private func handlePanelKey(_ e: NSEvent) -> Bool {
        guard panel.isVisible else { return false }
        // Never steal Return from an active IME composition in the search field.
        if let tv = panel.firstResponder as? NSTextView, tv.hasMarkedText() { return false }
        // Naming a pinboard: Return belongs to the text field, not to paste.
        if state.editingBoard != nil { return false }
        guard let item = state.item(state.selection) else { return false }
        let s = Settings.shared
        if s.markdownShortcut.matches(e) { state.pasteAsMarkdown(item); return true }
        if s.plainShortcut.matches(e) { state.paste(item, plain: true); return true }
        let isReturn = e.keyCode == UInt16(kVK_Return) || e.keyCode == UInt16(kVK_ANSI_KeypadEnter)
        if isReturn, e.modifierFlags.intersection(Shortcut.mask).isEmpty { state.paste(item); return true }
        return false
    }

    private func removeOutsideClickMonitor() {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
        outsideClickMonitor = nil
    }

    func hidePanel() {
        guard panel.isVisible, !animating else { return }
        state.commitEdit()          // finish naming a board if the panel closes mid-edit
        state.previewing = false
        removeOutsideClickMonitor()
        animating = true
        slide(from: 0, to: -panelHeight, duration: 0.2,
              timing: CAMediaTimingFunction(name: .easeIn)) { [weak self] in
            self?.panel.orderOut(nil)
            self?.slideView.layer?.removeAnimation(forKey: "slide")
            self?.animating = false
        }
    }

    func togglePanel() { panel.isVisible ? hidePanel() : showPanel() }

    // MARK: Status item + plugin menu
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "ClipDown")
        let menu = NSMenu()
        let open = menu.addItem(withTitle: "打开剪贴板历史", action: #selector(openPanel), keyEquivalent: "")
        open.target = self
        openItem = open
        menu.addItem(.separator())

        let header = NSMenuItem(title: "插件", action: nil, keyEquivalent: ""); header.isEnabled = false
        menu.addItem(header)
        for p in state.plugins.plugins {
            let enable = NSMenuItem(title: p.name, action: #selector(togglePlugin(_:)), keyEquivalent: "")
            enable.target = self; enable.representedObject = p.id
            enable.toolTip = p.summary
            pluginItems["e." + p.id] = enable; menu.addItem(enable)
            if p.supportsAutoRun {
                let auto = NSMenuItem(title: "自动运行:复制时处理", action: #selector(toggleAuto(_:)), keyEquivalent: "")
                auto.target = self; auto.representedObject = p.id; auto.indentationLevel = 1
                pluginItems["a." + p.id] = auto; menu.addItem(auto)
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "清空历史(保留固定项)", action: #selector(clearHistory), keyEquivalent: "").target = self
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.delegate = self
        statusItem.menu = menu
        refreshMenu()
    }

    func refreshMenu() {
        for p in state.plugins.plugins {
            pluginItems["e." + p.id]?.state = state.plugins.isEnabled(p) ? .on : .off
            if let a = pluginItems["a." + p.id] {
                a.state = state.plugins.isAutoRun(p) ? .on : .off
                a.isEnabled = state.plugins.isEnabled(p)
            }
        }
    }

    @objc func openPanel() { showPanel() }
    @objc func clearHistory() { state.store.clear() }
    @objc func togglePlugin(_ s: NSMenuItem) {
        guard let p = state.plugins.plugins.first(where: { $0.id == s.representedObject as? String }) else { return }
        state.plugins.setEnabled(p, !state.plugins.isEnabled(p)); refreshMenu()
    }
    @objc func toggleAuto(_ s: NSMenuItem) {
        guard let p = state.plugins.plugins.first(where: { $0.id == s.representedObject as? String }) else { return }
        state.plugins.setAutoRun(p, !state.plugins.isAutoRun(p)); refreshMenu()
    }

    // MARK: Global hotkey (configurable)
    func registerHotKey() {
        if !hotKeyHandlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, ud in
                let me = Unmanaged<AppDelegate>.fromOpaque(ud!).takeUnretainedValue()
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if hk.id == 2 { me.richPasteHotKey() } else { me.togglePanel() }
                    }
                }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
            hotKeyHandlerInstalled = true
        }
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let ref = richHotKeyRef { UnregisterEventHotKey(ref); richHotKeyRef = nil }
        let sc = Settings.shared.openShortcut
        RegisterEventHotKey(UInt32(sc.keyCode), sc.carbonModifiers,
                            EventHotKeyID(signature: OSType(0x434C5053), id: 1),
                            GetApplicationEventTarget(), 0, &hotKeyRef)
        let rc = Settings.shared.markdownShortcut
        RegisterEventHotKey(UInt32(rc.keyCode), rc.carbonModifiers,
                            EventHotKeyID(signature: OSType(0x434C5053), id: 2),
                            GetApplicationEventTarget(), 0, &richHotKeyRef)
        openItem?.title = "打开剪贴板历史  (\(sc.display))"
    }

    /// Global ⌘⇧V. With the panel open it pastes the selected card as rich text;
    /// otherwise it converts whatever Markdown is on the clipboard.
    func richPasteHotKey() {
        if ProcessInfo.processInfo.environment["CLIPDOWN_DEBUG"] != nil {
            FileHandle.standardError.write(Data("richPasteHotKey fired, AX trusted=\(AXIsProcessTrusted()), panelVisible=\(panel.isVisible)\n".utf8))
        }
        if panel.isVisible, let item = state.item(state.selection) {
            state.pasteAsMarkdown(item)
        } else {
            state.pasteClipboardAsRich()
        }
    }

    // MARK: History retention
    func startPurgeTimer() {
        purgeNow()
        purgeTimer?.invalidate()
        purgeTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.purgeNow() }
        }
    }

    func purgeNow() {
        guard let cutoff = Settings.shared.retention.cutoff else { return }
        state.store.purge(olderThan: cutoff)
    }

    // MARK: Settings window
    @objc func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: Settings.shared) { [weak self] in
                self?.registerHotKey()
                self?.purgeNow()
            }
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "ClipDown 设置"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 460, height: 360))
            w.center()
            settingsWindow = w
        }
        hidePanel()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) { refreshMenu() }
}

/// One-time carry-over from the app's previous name ("ClipStack"): history, pinboards and settings.
/// Runs before anything reads either location; never overwrites data that already exists.
func migrateLegacyData() {
    let fm = FileManager.default
    let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let old = support.appendingPathComponent("ClipStack", isDirectory: true)
    let new = support.appendingPathComponent("ClipDown", isDirectory: true)
    if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) {
        try? fm.moveItem(at: old, to: new)
    }
    // Preferences live in a domain named after the bundle id (or the executable name when run
    // unbundled), so settings made under an earlier name / packaging are carried over once.
    let defaults = UserDefaults.standard
    let flag = "migrated.legacyDefaults"
    guard !defaults.bool(forKey: flag) else { return }
    let current = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
    for domain in ["ClipDown", "ClipStack"] where domain != current {
        guard let legacy = defaults.persistentDomain(forName: domain) else { continue }
        for (k, v) in legacy where !k.hasPrefix("migrated.") && defaults.object(forKey: k) == nil {
            defaults.set(v, forKey: k)
        }
    }
    defaults.set(true, forKey: flag)
}

MainActor.assumeIsolated {
    migrateLegacyData()
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
