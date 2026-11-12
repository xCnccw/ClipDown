import AppKit
import SwiftUI

/// Click, then press the desired combination. Esc cancels.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut
    var requireModifier = false

    func makeNSView(context: Context) -> RecorderButton {
        let b = RecorderButton()
        b.onRecord = { new in
            if requireModifier && new.flags.intersection(Shortcut.mask).isEmpty { NSSound.beep(); return false }
            shortcut = new
            return true
        }
        return b
    }

    func updateNSView(_ b: RecorderButton, context: Context) { b.refresh(shortcut) }
}

final class RecorderButton: NSButton {
    var onRecord: ((Shortcut) -> Bool)?
    private var recording = false { didSet { updateTitle() } }
    private var current: Shortcut?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self; action = #selector(toggle)
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh(_ s: Shortcut) { current = s; updateTitle() }
    private func updateTitle() { title = recording ? "按下新的快捷键…" : (current?.display ?? "—") }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }

    @objc private func toggle() { recording.toggle(); if recording { window?.makeFirstResponder(self) } }
    override func resignFirstResponder() -> Bool { recording = false; return super.resignFirstResponder() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        handle(event); return true
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        handle(event)
    }

    private func handle(_ e: NSEvent) {
        if e.keyCode == 53 { recording = false; return }          // Esc cancels
        if onRecord?(Shortcut.from(e)) == true { recording = false }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    var onChange: () -> Void

    var body: some View {
        Form {
            Section("快捷键") {
                row("呼出剪贴板面板", $settings.openShortcut, requireModifier: true)
                row("面板内以纯文本粘贴", $settings.plainShortcut)
                row("Markdown 转富文本粘贴(全局)", $settings.markdownShortcut, requireModifier: true)
                HStack {
                    Text("⌘V 粘贴 Markdown 原文;↩ 粘贴选中项原文;⌘1–⌘9 快速粘贴(固定)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("恢复默认") { settings.resetShortcuts() }
                }
            }
            Section("历史记录") {
                Picker("保留时间", selection: $settings.retention) {
                    ForEach(Retention.allCases) { Text($0.title).tag($0) }
                }
                Text("超过保留时间的记录会被自动删除;已加入固定板的内容不会被删除。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 360)
        .onChange(of: settings.openShortcut) { _, _ in onChange() }
        .onChange(of: settings.markdownShortcut) { _, _ in onChange() }
        .onChange(of: settings.retention) { _, _ in onChange() }
    }

    private func row(_ title: String, _ binding: Binding<Shortcut>, requireModifier: Bool = false) -> some View {
        HStack {
            Text(title)
            Spacer()
            ShortcutRecorder(shortcut: binding, requireModifier: requireModifier).frame(width: 150, height: 24)
        }
    }
}
