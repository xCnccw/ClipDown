import Foundation
import ClipCore

/// "cp2md": converts Markdown text into rich text (HTML + RTF) on demand.
/// Entirely self-contained; the app enables it with `plugins.register(MarkdownPlugin())`.
///
/// Conversion is explicit (⌘⇧V / the "paste as rich text" key / the card menu). The plugin
/// never rewrites what is on the clipboard by itself, so a plain ⌘V pastes the Markdown source.
public struct MarkdownPlugin: ClipPlugin {
    public init() {}

    public let id = "md2rich"
    public let name = "Markdown → Rich Text"
    public let summary = "Convert copied Markdown to formatted rich text (ChatGPT-style) with ⌘⇧V."
    public var enabledByDefault: Bool { true }
    public var supportsAutoRun: Bool { false }

    public func actions(for item: ClipItem) -> [ClipAction] {
        guard item.kind == .text, let t = item.text, MarkdownConverter.looksLikeMarkdown(t) else { return [] }
        return [ClipAction(id: "md2rich.convert", title: "Convert Markdown to Rich Text",
                           symbol: "textformat") { convert($0) }]
    }

    /// Rich flavors for a piece of Markdown, regardless of whether it "looks like" Markdown
    /// (the user explicitly asked for rich text). Nil only if RTF generation fails.
    public static func richFlavors(from markdown: String) -> (html: String, rtf: Data)? {
        let html = MarkdownConverter.html(from: markdown)
        let rtfHTML = MarkdownConverter.html(from: markdown, forRTF: true)
        guard let rtf = RichText.rtf(fromHTML: rtfHTML) else { return nil }
        return (html, rtf)
    }

    private func convert(_ item: ClipItem) -> ClipItem? {
        guard let md = item.text, let rich = Self.richFlavors(from: md) else { return nil }
        var out = item
        out.html = rich.html
        out.rtf = rich.rtf
        return out
    }
}
