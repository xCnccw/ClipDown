import AppKit
import Combine
import ClipCore
import MarkdownPlugin
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    let store = HistoryStore()
    let plugins = PluginManager()
    let monitor = ClipboardMonitor()

    @Published var query = ""
    @Published var searching = false
    /// nil = the rolling clipboard history; otherwise a pinboard.
    @Published var currentBoard: UUID?
    @Published var selection: UUID?
    @Published var previewing = false
    @Published var editingBoard: UUID?
    @Published var editingText = ""
    var editingIsNew = false

    var onDismiss: (() -> Void)?
    var previousApp: NSRunningApplication?
    private var bag = Set<AnyCancellable>()

    init() {
        store.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        plugins.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        monitor.onItem = { [weak self] item, img in
            guard let self else { return }
            let processed = self.plugins.processCapture(item)
            // Never touch the live pasteboard here: a plain ⌘V must paste what was copied.
            self.store.add(processed, imageData: img)
        }
        monitor.start()
        // A board left unnamed (app quit mid-edit) would show as a blank tab.
        for b in store.boards where b.name.isEmpty { store.removeBoard(b.id) }
    }

    var visible: [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.items.filter { it in
            if let b = currentBoard, it.boardID != b { return false }
            if q.isEmpty { return true }
            return (it.text ?? "").lowercased().contains(q) || (it.sourceApp ?? "").lowercased().contains(q)
        }
    }

    // MARK: selection / navigation
    func move(_ delta: Int) {
        let v = visible
        guard !v.isEmpty else { return }
        let cur = v.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : v.count)
        selection = v[max(0, min(v.count - 1, cur + delta))].id
    }

    func ensureSelection() {
        if selection == nil || !visible.contains(where: { $0.id == selection }) { selection = visible.first?.id }
    }

    func item(_ id: UUID?) -> ClipItem? { store.items.first { $0.id == id } }

    /// Tab: history -> board 1 -> board 2 -> ... -> history
    func cycleBoard() {
        let ids: [UUID?] = [nil] + store.boards.map { $0.id }
        let i = ids.firstIndex(where: { $0 == currentBoard }) ?? 0
        currentBoard = ids[(i + 1) % ids.count]
    }

    func beginSearch(with text: String = "") { searching = true; query += text }
    func endSearch() { searching = false; query = "" }

    // MARK: pasting
    /// Paste the item exactly as it was copied (Markdown stays Markdown source).
    func paste(_ item: ClipItem, plain: Bool = false) {
        PasteboardWriter.write(item, plain: plain, store: store, monitor: monitor)
        dismissAndPaste()
    }

    /// Paste a history item with its Markdown converted to rich text (explicit request only).
    func pasteAsMarkdown(_ item: ClipItem) {
        guard item.kind == .text, let text = item.text,
              let rich = MarkdownPlugin.richFlavors(from: text) else {
            paste(item, plain: true)
            return
        }
        var converted = item
        converted.html = rich.html
        converted.rtf = rich.rtf
        PasteboardWriter.write(converted, store: store, monitor: monitor)
        dismissAndPaste()
    }

    /// Global "paste as rich text" (⌘⇧V in any app): convert the Markdown currently on the
    /// clipboard, paste it, then put the original clipboard contents back so that the next
    /// plain ⌘V still pastes the Markdown source.
    func pasteClipboardAsRich() {
        guard AXIsProcessTrusted() else {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            return
        }
        let pb = NSPasteboard.general
        guard let text = pb.string(forType: .string), !text.isEmpty,
              let rich = MarkdownPlugin.richFlavors(from: text) else {
            Self.sendCommandV(after: 0.05, deadline: Date().addingTimeInterval(1.0))   // nothing to convert
            return
        }
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setData(rich.rtf, forType: .rtf)
        pb.setString(rich.html, forType: .html)
        monitor.ignoreCurrentChange()
        let ours = pb.changeCount

        Self.sendCommandV(after: 0.05, deadline: Date().addingTimeInterval(1.0)) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard pb.changeCount == ours else { return }       // the user copied something new
                pb.clearContents()
                let items: [NSPasteboardItem] = saved.map { pairs in
                    let it = NSPasteboardItem()
                    for (t, d) in pairs { it.setData(d, forType: t) }
                    return it
                }
                pb.writeObjects(items)
                self?.monitor.ignoreCurrentChange()
            }
        }
    }

    func copyOnly(_ item: ClipItem) {
        PasteboardWriter.write(item, store: store, monitor: monitor)
        onDismiss?()
    }

    func run(_ action: ClipAction, on item: ClipItem) {
        if let new = action.run(item) { store.replace(id: item.id, with: new) }
    }

    private func dismissAndPaste() {
        onDismiss?()
        previousApp?.activate()
        guard AXIsProcessTrusted() else {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            return
        }
        Self.sendCommandV(after: 0.12, deadline: Date().addingTimeInterval(1.0))
    }

    /// Posts ⌘V. If the user triggered the paste with ⇧↩ / ⌥↩ they are probably still holding
    /// Shift/Option, which would turn our synthetic ⌘V into ⇧⌘V / ⌥⌘V (a different command in
    /// most apps). So wait for those keys to be released (bounded), and use a private event
    /// source so physical modifier state is never merged into the event.
    private static func sendCommandV(after delay: TimeInterval, deadline: Date,
                                     completion: (() -> Void)? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let held = NSEvent.modifierFlags.intersection([.shift, .option, .control, .command])
            if !held.isEmpty, Date() < deadline {
                sendCommandV(after: 0.02, deadline: deadline, completion: completion)
                return
            }
            let src = CGEventSource(stateID: .privateState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand; up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
            completion?()
        }
    }

    // MARK: pinboards (inline naming)
    /// Click "+": a new board appears in the tab bar with a text field to name it.
    func beginNewBoard() {
        let color = boardPalette[store.boards.count % boardPalette.count]
        let board = store.addBoard(name: "", colorHex: color)
        currentBoard = board.id
        editingBoard = board.id; editingIsNew = true; editingText = ""
    }

    func beginRename(_ board: Board) {
        editingBoard = board.id; editingIsNew = false; editingText = board.name
    }

    /// Return / focus lost. An empty name on a brand-new board discards it.
    func commitEdit() {
        guard let id = editingBoard else { return }
        let name = editingText.trimmingCharacters(in: .whitespaces)
        let wasNew = editingIsNew
        editingBoard = nil; editingIsNew = false
        if name.isEmpty {
            if wasNew { if currentBoard == id { currentBoard = nil }; store.removeBoard(id) }
        } else {
            store.renameBoard(id, to: name)
        }
    }

    func cancelEdit() {
        guard let id = editingBoard else { return }
        let wasNew = editingIsNew
        editingBoard = nil; editingIsNew = false
        if wasNew { if currentBoard == id { currentBoard = nil }; store.removeBoard(id) }
    }

    var isTyping: Bool { searching || editingBoard != nil }

    func deleteBoard(_ board: Board) {
        if currentBoard == board.id { currentBoard = nil }
        store.removeBoard(board.id)
    }

    /// ⌘P: toggle the item on the first board (created on demand).
    func quickPin(_ item: ClipItem) {
        if item.boardID != nil { store.assign(item.id, to: nil); return }
        let board = store.boards.first ?? store.addBoard(name: "固定", colorHex: boardPalette[0])
        store.assign(item.id, to: board.id)
    }
}
