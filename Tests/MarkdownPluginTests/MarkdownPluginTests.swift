import XCTest
import AppKit
import ClipCore
import MarkdownPlugin

final class MarkdownPluginTests: XCTestCase {
    func testMarkdownDetectionAndRichOutput() throws {
        let source = """
        # 标题

        这是 **粗体** 和 `code`。

        - 第一项
        - 第二项
        """
        XCTAssertTrue(MarkdownConverter.looksLikeMarkdown(source))

        let plugin = MarkdownPlugin()
        let item = ClipItem(kind: .text, text: source)
        let action = try XCTUnwrap(plugin.actions(for: item).first)
        let converted = try XCTUnwrap(action.run(item))

        XCTAssertFalse(converted.html?.isEmpty ?? true)
        XCTAssertFalse(converted.rtf?.isEmpty ?? true)
        XCTAssertTrue(converted.html?.contains("<h1") == true)
        XCTAssertTrue(converted.html?.contains("<b>粗体</b>") == true)
    }

    func testNormalTextIsNotConverted() {
        let item = ClipItem(kind: .text, text: "hello world")
        XCTAssertTrue(MarkdownPlugin().actions(for: item).isEmpty)
        XCTAssertNil(MarkdownPlugin().onCapture(item))
    }
}
