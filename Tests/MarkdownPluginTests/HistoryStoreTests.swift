import XCTest
import ClipCore

final class HistoryStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipdown-test-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func store(max: Int = 100) -> HistoryStore { HistoryStore(maxItems: max, directory: dir) }
    private func text(_ s: String, daysAgo: Int = 0) -> ClipItem {
        ClipItem(date: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!, kind: .text, text: s)
    }

    func testNewestFirstAndDedupeMovesToTop() {
        let s = store()
        s.add(text("a")); s.add(text("b")); s.add(text("a"))
        XCTAssertEqual(s.items.compactMap(\.text), ["a", "b"])
    }

    func testPersistsAcrossReload() {
        let s = store()
        s.add(text("keep me"))
        XCTAssertEqual(store().items.first?.text, "keep me")
    }

    func testDedupeKeepsBoardMembership() {
        let s = store()
        let board = s.addBoard(name: "x", colorHex: "#fff")
        s.add(text("a"))
        s.assign(s.items[0].id, to: board.id)
        s.add(text("a"))
        XCTAssertEqual(s.items.count, 1)
        XCTAssertEqual(s.items[0].boardID, board.id)
    }

    func testPurgeRemovesOldButKeepsBoardItems() {
        let s = store()
        let board = s.addBoard(name: "keep", colorHex: "#fff")
        s.add(text("old", daysAgo: 40))
        s.add(text("old-pinned", daysAgo: 40))
        s.add(text("recent", daysAgo: 1))
        let pinned = s.items.first { $0.text == "old-pinned" }!
        s.assign(pinned.id, to: board.id)

        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        XCTAssertEqual(s.purge(olderThan: cutoff), 1)
        XCTAssertEqual(Set(s.items.compactMap(\.text)), ["recent", "old-pinned"])
    }

    func testRemovingBoardUnassignsItems() {
        let s = store()
        let board = s.addBoard(name: "b", colorHex: "#fff")
        s.add(text("a"))
        s.assign(s.items[0].id, to: board.id)
        s.removeBoard(board.id)
        XCTAssertNil(s.items[0].boardID)
        XCTAssertTrue(s.boards.isEmpty)
    }

    func testBoardRenameAndColor() {
        let s = store()
        let b = s.addBoard(name: "", colorHex: "#111111")
        s.renameBoard(b.id, to: "links")
        s.setBoardColor(b.id, hex: "#222222")
        let reloaded = store()
        XCTAssertEqual(reloaded.boards.first?.name, "links")
        XCTAssertEqual(reloaded.boards.first?.colorHex, "#222222")
    }

    func testClearKeepsBoardItems() {
        let s = store()
        let b = s.addBoard(name: "b", colorHex: "#fff")
        s.add(text("a")); s.add(text("b"))
        s.assign(s.items.first { $0.text == "a" }!.id, to: b.id)
        s.clear()
        XCTAssertEqual(s.items.compactMap(\.text), ["a"])
    }

    func testTrimDropsOldestUnpinnedOverLimit() {
        let s = store(max: 3)
        for i in 1...5 { s.add(text("\(i)")) }
        XCTAssertEqual(s.items.compactMap(\.text), ["5", "4", "3"])
    }

    func testLinkAndFileHelpers() {
        XCTAssertNotNil(ClipItem(kind: .text, text: "https://example.com/a?b=1").linkURL)
        XCTAssertNil(ClipItem(kind: .text, text: "see https://example.com").linkURL)
        XCTAssertNil(ClipItem(kind: .text, text: "not a url").linkURL)
        XCTAssertEqual(ClipItem(kind: .file, text: "/a/b\n/c/d").filePaths, ["/a/b", "/c/d"])
    }
}
