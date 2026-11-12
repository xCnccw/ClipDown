import AppKit

/// Persistent clipboard history. JSON metadata + PNG files for images.
public final class HistoryStore: ObservableObject {
    @Published public private(set) var items: [ClipItem] = []
    @Published public private(set) var boards: [Board] = []
    public let directory: URL
    private let imagesDir: URL
    private let maxItems: Int
    private let thumbs = NSCache<NSString, NSImage>()

    /// `directory` is injectable so tests never touch the real history.
    public init(maxItems: Int = 10_000, directory: URL? = nil) {
        self.maxItems = maxItems
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipDown", isDirectory: true)
        self.directory = base
        imagesDir = base.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        load()
        loadBoards()
    }

    private var file: URL { directory.appendingPathComponent("history.json") }

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        items = (try? dec.decode([ClipItem].self, from: data)) ?? []
    }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(items) { try? data.write(to: file, options: .atomic) }
    }

    public func add(_ item: ClipItem, imageData: Data? = nil) {
        var it = item
        if let d = imageData {
            let name = it.id.uuidString + ".png"
            try? d.write(to: imagesDir.appendingPathComponent(name))
            it.imageFile = name
        }
        if let idx = items.firstIndex(where: { $0.key == it.key }) {
            let old = items.remove(at: idx)
            it.pinned = old.pinned
            it.boardID = old.boardID
            if it.kind == .image, let oldFile = old.imageFile {
                if let newFile = it.imageFile, newFile != oldFile { removeImage(newFile) }
                it.imageFile = oldFile
            }
        }
        items.insert(it, at: 0)
        trim()
        save()
    }

    /// Replace an item's content in place (used by plugins), keeping id and position.
    public func replace(id: UUID, with new: ClipItem) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        var n = new; n.id = id; n.pinned = items[idx].pinned
        items[idx] = n
        save()
    }

    private var boardsFile: URL { directory.appendingPathComponent("boards.json") }
    private func loadBoards() {
        if let d = try? Data(contentsOf: boardsFile), let b = try? JSONDecoder().decode([Board].self, from: d) { boards = b }
    }
    private func saveBoards() { if let d = try? JSONEncoder().encode(boards) { try? d.write(to: boardsFile, options: .atomic) } }

    @discardableResult
    public func addBoard(name: String, colorHex: String) -> Board {
        let b = Board(name: name, colorHex: colorHex); boards.append(b); saveBoards(); return b
    }
    public func renameBoard(_ id: UUID, to name: String) {
        guard let i = boards.firstIndex(where: { $0.id == id }) else { return }
        boards[i].name = name; saveBoards()
    }
    public func setBoardColor(_ id: UUID, hex: String) {
        guard let i = boards.firstIndex(where: { $0.id == id }) else { return }
        boards[i].colorHex = hex; saveBoards()
    }
    public func removeBoard(_ id: UUID) {
        boards.removeAll { $0.id == id }
        for i in items.indices where items[i].boardID == id { items[i].boardID = nil }
        saveBoards(); save()
    }
    public func assign(_ itemID: UUID, to board: UUID?) {
        guard let i = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[i].boardID = board; save()
    }

    /// Delete history older than `date`. Items on a pinboard (or legacy-pinned) are always kept.
    @discardableResult
    public func purge(olderThan date: Date) -> Int {
        let doomed = items.filter { $0.date < date && !$0.pinned && $0.boardID == nil }
        guard !doomed.isEmpty else { return 0 }
        for it in doomed { if let f = it.imageFile { removeImage(f) } }
        let ids = Set(doomed.map(\.id))
        items.removeAll { ids.contains($0.id) }
        save()
        return doomed.count
    }

    public func togglePin(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].pinned.toggle(); save()
    }

    public func remove(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        if let f = items[idx].imageFile { removeImage(f) }
        items.remove(at: idx); save()
    }

    public func clear(keepPinned: Bool = true) {
        func keep(_ i: ClipItem) -> Bool { keepPinned && (i.pinned || i.boardID != nil) }
        for it in items where !keep(it) { if let f = it.imageFile { removeImage(f) } }
        items.removeAll { !keep($0) }
        save()
    }

    public func imageData(for item: ClipItem) -> Data? {
        guard let f = item.imageFile else { return nil }
        return try? Data(contentsOf: imagesDir.appendingPathComponent(f))
    }

    public func thumbnail(for item: ClipItem) -> NSImage? {
        guard let f = item.imageFile else { return nil }
        if let c = thumbs.object(forKey: f as NSString) { return c }
        guard let img = NSImage(contentsOf: imagesDir.appendingPathComponent(f)) else { return nil }
        thumbs.setObject(img, forKey: f as NSString)
        return img
    }

    private func removeImage(_ name: String) {
        try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(name))
        thumbs.removeObject(forKey: name as NSString)
    }

    private func trim() {
        while items.count > maxItems, let i = items.lastIndex(where: { !$0.pinned && $0.boardID == nil }) {
            if let f = items[i].imageFile { removeImage(f) }
            items.remove(at: i)
        }
    }
}
