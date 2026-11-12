import Foundation

/// Dependency-free Markdown -> HTML converter.
/// Block: ATX/setext headings, fenced code (``` and ~~~), indented code, blockquotes (nested),
///        ordered/unordered/nested/task lists, GFM tables with alignment, hr, paragraphs.
/// Inline: bold, italic, bold-italic, strike, code, links, images, autolinks, hard breaks, escapes.
public enum MarkdownConverter {
    public static func looksLikeMarkdown(_ s: String) -> Bool {
        let patterns = [#"(?m)^#{1,6}\s"#, #"\*\*.+?\*\*"#, #"(?m)^\s*[-*+]\s"#, #"(?m)^\s*\d+\.\s"#,
                        #"`.+?`"#, #"\[.+?\]\(.+?\)"#, #"(?m)^(```|~~~)"#, #"(?m)^>\s"#, #"(?m)^\|.+\|\s*$"#]
        return patterns.contains { s.range(of: $0, options: .regularExpression) != nil }
    }

    /// When true, emit markup tuned for Cocoa's HTML->RTF importer (which ignores most block CSS).
    nonisolated(unsafe) private static var rtfMode = false

    public static func html(from md: String, forRTF: Bool = false) -> String {
        rtfMode = forRTF
        defer { rtfMode = false }
        let lines = md.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "    ")
            .components(separatedBy: "\n")
        let body = blocks(lines)
        return "<html><head><meta charset=\"utf-8\"></head><body style=\"\(T.body)\">\n\(body)</body></html>"
    }

    // MARK: - Block level

    /// ChatGPT-like theme (inline styles so HTML-aware apps keep them; RTF keeps what it can).
    private enum T {
        static let text = "#0d0d0d", muted = "#5d5d5d", border = "#e5e5e5", codeBg = "#f3f3f3", blockBg = "#f9f9f9"
        static let sans = "-apple-system,'SF Pro Text','Helvetica Neue','PingFang SC',Arial,sans-serif"
        static let mono = "ui-monospace,'SF Mono',Menlo,Consolas,monospace"
        static let body = "font-family:\(sans);font-size:16px;line-height:1.6;color:\(text)"
        static let p = "margin:0 0 16px 0;line-height:1.6"
        static let list = "margin:0 0 16px 0;padding-left:28px"
        static let li = "margin:4px 0;line-height:1.6"
        static let hr = "border:none;border-top:1px solid \(border);margin:24px 0"
        static let a = "color:\(text);text-decoration:underline"
        static let code = "font-family:\(mono);font-size:14px;background-color:\(codeBg);padding:2px 6px;border-radius:6px"
        static let pre = "background-color:\(blockBg);border:1px solid \(border);border-radius:12px;padding:16px;margin:0 0 16px 0;overflow-x:auto;line-height:1.5"
        static let preCode = "font-family:\(mono);font-size:14px;background:none;padding:0"
        static let quote = "border-left:4px solid #d9d9d9;margin:0 0 16px 0;padding:0 0 0 16px;color:\(muted)"
        static let table = "border-collapse:collapse;margin:0 0 16px 0;font-size:15px"
        static func heading(_ l: Int) -> String {
            let size = [1: 28, 2: 24, 3: 20, 4: 18, 5: 16, 6: 16][l] ?? 16
            let weight = l <= 2 ? 700 : 600
            let top = l == 1 ? 32 : 24
            return "font-size:\(size)px;font-weight:\(weight);line-height:1.3;margin:\(top)px 0 12px 0;color:\(l == 6 ? muted : text)"
        }
    }
    private static let listRe = #"^(\s*)([-*+]|\d+[.)])\s+(.*)$"#

    private static func blocks(_ lines: [String]) -> String {
        var out = ""
        var i = 0
        var para: [String] = []

        func flush() {
            guard !para.isEmpty else { return }
            out += "<p style=\"\(T.p)\">" + para.enumerated().map { idx, l in
                let hard = l.hasSuffix("  ") || l.hasSuffix("\\")
                let t = l.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
                return inline(t) + (idx < para.count - 1 ? (hard ? "<br>" : " ") : "")
            }.joined() + "</p>\n"
            para = []
        }

        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)

            if t.isEmpty { flush(); i += 1; continue }

            // Fenced code
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                flush()
                let fence = String(t.prefix(3))
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                i += 1
                out += codeBlock(code)
                continue
            }

            // Indented code (only when not continuing a paragraph)
            if para.isEmpty, line.hasPrefix("    "), line.range(of: listRe, options: .regularExpression) == nil {
                var code: [String] = []
                while i < lines.count, lines[i].hasPrefix("    ") || lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    code.append(String(lines[i].dropFirst(min(4, lines[i].count)))); i += 1
                }
                while code.last?.isEmpty == true { code.removeLast() }
                out += codeBlock(code)
                continue
            }

            // ATX heading
            if let m = t.range(of: #"^#{1,6}(\s+|$)"#, options: .regularExpression) {
                flush()
                let level = t[m].filter { $0 == "#" }.count
                var text = String(t[m.upperBound...])
                text = text.replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
                out += "<h\(level) style=\"\(T.heading(level))\"><b>\(inline(text))</b></h\(level)>\n"
                i += 1; continue
            }

            // Setext heading
            if !para.isEmpty, t.range(of: #"^(=+|-+)$"#, options: .regularExpression) != nil, para.count >= 1 {
                let level = t.hasPrefix("=") ? 1 : 2
                let text = para.joined(separator: " ")
                para = []
                out += "<h\(level) style=\"\(T.heading(level))\"><b>\(inline(text.trimmingCharacters(in: .whitespaces)))</b></h\(level)>\n"
                i += 1; continue
            }

            // HR
            if t.range(of: #"^([-*_][ ]*){3,}$"#, options: .regularExpression) != nil {
                flush(); out += rtfMode
                    ? "<p style=\"color:#c8c8c8;margin:8px 0 16px 0\">" + String(repeating: "\u{2500}", count: 40) + "</p>\n"
                    : "<hr style=\"\(T.hr)\">\n"; i += 1; continue
            }

            // Blockquote (recursive, so nested quotes/lists work)
            if t.hasPrefix(">") {
                flush()
                var q: [String] = []
                while i < lines.count {
                    let s = lines[i].trimmingCharacters(in: .whitespaces)
                    guard s.hasPrefix(">") else { break }
                    var r = String(s.dropFirst())
                    if r.hasPrefix(" ") { r.removeFirst() }
                    q.append(r); i += 1
                }
                var inner = blocks(q)
                if rtfMode {
                    inner = inner.replacingOccurrences(of: "<p style=\"\(T.p)\">", with: "<p style=\"\(T.p);color:\(T.muted)\"><span style=\"color:#bdbdbd\">\u{258E}</span>&nbsp;")
                }
                out += "<blockquote style=\"\(T.quote)\">\(inner)</blockquote>\n"
                continue
            }

            // Table
            if t.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flush()
                let header = splitRow(t)
                let aligns = splitRow(lines[i + 1]).map { c -> String in
                    let a = c.hasPrefix(":"), b = c.hasSuffix(":")
                    return a && b ? "center" : b ? "right" : a ? "left" : ""
                }
                i += 2
                var rows: [[String]] = []
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(splitRow(lines[i])); i += 1
                }
                func cell(_ tag: String, _ text: String, _ idx: Int) -> String {
                    let al = idx < aligns.count && !aligns[idx].isEmpty ? "text-align:\(aligns[idx]);" : ""
                    let bg = tag == "th" ? "background-color:#f7f7f7;font-weight:600;" : ""
                    return "<\(tag) style=\"border:1px solid \(T.border);padding:8px 12px;\(al)\(bg)\">\(inline(text))</\(tag)>"
                }
                out += "<table style=\"\(T.table)\" border=\"1\" cellpadding=\"8\" cellspacing=\"0\">\n<thead><tr>"
                out += header.enumerated().map { cell("th", $1, $0) }.joined() + "</tr></thead>\n<tbody>\n"
                for r in rows {
                    out += "<tr>" + (0..<header.count).map { cell("td", $0 < r.count ? r[$0] : "", $0) }.joined() + "</tr>\n"
                }
                out += "</tbody></table>\n"
                continue
            }

            // Lists
            if line.range(of: listRe, options: .regularExpression) != nil {
                flush()
                out += parseList(lines, &i)
                continue
            }

            para.append(line)
            i += 1
        }
        flush()
        return out
    }

    private static func codeBlock(_ code: [String]) -> String {
        if rtfMode {
            let lines = code.map { l -> String in
                let e = escape(l).replacingOccurrences(of: " ", with: "&nbsp;")
                return "<span style=\"background-color:\(T.codeBg);font-family:\(T.mono);font-size:13px\">&nbsp;\(e.isEmpty ? "&nbsp;" : e)&nbsp;</span>"
            }
            return "<p style=\"margin:4px 0 16px 0\">" + lines.joined(separator: "<br>") + "</p>\n"
        }
        return "<pre style=\"\(T.pre)\"><code style=\"\(T.preCode)\">\(escape(code.joined(separator: "\n")))</code></pre>\n"
    }

    private struct Item { var indent: Int; var ordered: Bool; var text: String; var children: [String] = [] }

    /// Parses a (possibly nested) list starting at lines[i]; advances i.
    private static func parseList(_ lines: [String], _ i: inout Int) -> String {
        var items: [Item] = []
        while i < lines.count {
            let l = lines[i]
            if let re = try? NSRegularExpression(pattern: listRe),
               let m = re.firstMatch(in: l, range: NSRange(location: 0, length: (l as NSString).length)) {
                let ns = l as NSString
                let indent = ns.substring(with: m.range(at: 1)).count
                let marker = ns.substring(with: m.range(at: 2))
                let ordered = marker.first!.isNumber
                if let f = items.first, indent <= f.indent, ordered != f.ordered { break }
                items.append(Item(indent: indent, ordered: ordered, text: ns.substring(with: m.range(at: 3))))
                i += 1
            } else if l.trimmingCharacters(in: .whitespaces).isEmpty {
                // blank line: continue list only if next non-blank line is a list item
                var j = i + 1
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                if j < lines.count, lines[j].range(of: listRe, options: .regularExpression) != nil { i = j } else { break }
            } else if l.hasPrefix("  "), !items.isEmpty {
                items[items.count - 1].text += " " + l.trimmingCharacters(in: .whitespaces); i += 1 // lazy continuation
            } else { break }
        }
        var idx = 0
        return renderList(items, &idx, items.first?.indent ?? 0)
    }

    private static func renderList(_ items: [Item], _ idx: inout Int, _ base: Int) -> String {
        guard idx < items.count else { return "" }
        let tag = items[idx].ordered ? "ol" : "ul"
        var s = "<\(tag) style=\"\(T.list)\">\n"
        while idx < items.count, items[idx].indent >= base {
            if items[idx].indent > base { // deeper than expected: treat as nested of previous
                s += renderList(items, &idx, items[idx].indent); continue
            }
            var text = items[idx].text
            var prefix = ""
            if let r = text.range(of: #"^\[( |x|X)\]\s+"#, options: .regularExpression) {
                prefix = text[r].contains("[ ]") ? "☐ " : "☑ "
                text = String(text[r.upperBound...])
            }
            idx += 1
            s += "<li style=\"\(T.li)\">\(prefix)\(inline(text))"
            if idx < items.count, items[idx].indent > base {
                s += "\n" + renderList(items, &idx, items[idx].indent).replacingOccurrences(of: "margin:0 0 16px 0", with: "margin:4px 0 0 0", options: [], range: nil)
            }
            s += "</li>\n"
        }
        return s + "</\(tag)>\n"
    }

    private static func isTableSeparator(_ l: String) -> Bool {
        l.range(of: #"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$"#, options: .regularExpression) != nil && l.contains("-") && l.contains("|")
    }

    private static func splitRow(_ l: String) -> [String] {
        var s = l.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") && !s.hasSuffix("\\|") { s.removeLast() }
        var cells: [String] = [], cur = "", prevBackslash = false
        for ch in s {
            if ch == "|" && !prevBackslash { cells.append(cur.trimmingCharacters(in: .whitespaces)); cur = "" }
            else { cur.append(ch) }
            prevBackslash = ch == "\\"
        }
        cells.append(cur.trimmingCharacters(in: .whitespaces))
        return cells.map { $0.replacingOccurrences(of: "\\|", with: "|") }
    }

    // MARK: - Inline

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func inline(_ raw: String) -> String {
        var s = escape(raw)
        var stash: [String] = []
        func hold(_ html: String) -> String { stash.append(html); return "\u{1}\(stash.count - 1)\u{1}" }

        // backslash escapes
        s = replace(s, #"\\([\\`*_{}\[\]()#+\-.!|~>])"#) { hold($0[1]) }
        // inline code
        s = replace(s, #"(`+)(.+?)\1"#) { hold("<code style=\"\(T.code)\">\($0[2].trimmingCharacters(in: .whitespaces))</code>") }
        // images, links
        s = replace(s, #"!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^)]*")?\)"#) { hold("<img alt=\"\($0[1])\" src=\"\($0[2])\">") }
        s = replace(s, #"\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^)]*")?\)"#) { hold("<a style=\"\(T.a)\" href=\"\($0[2])\">\(inlineEmphasis($0[1]))</a>") }
        // autolinks <http://..> (escaped as &lt; &gt;) and bare URLs
        s = replace(s, #"&lt;(https?://[^\s&]+)&gt;"#) { hold("<a style=\"\(T.a)\" href=\"\($0[1])\">\($0[1])</a>") }
        s = replace(s, #"(?<![\"=>\x01])\bhttps?://[^\s<)\x01]+"#) { hold("<a style=\"\(T.a)\" href=\"\($0[0])\">\($0[0])</a>") }

        s = inlineEmphasis(s)
        // restore (repeat for nested holds)
        for _ in 0..<3 {
            s = replace(s, "\u{1}(\\d+)\u{1}") { Int($0[1]).flatMap { $0 < stash.count ? stash[$0] : nil } ?? "" }
        }
        return s
    }

    private static func inlineEmphasis(_ input: String) -> String {
        var s = input
        s = replace(s, #"(\*\*\*|___)(.+?)\1"#) { "<b><i>\($0[2])</i></b>" }
        s = replace(s, #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#) { "<b>\($0[2])</b>" }
        s = replace(s, #"~~(.+?)~~"#) { "<s>\($0[1])</s>" }
        s = replace(s, #"\*(?=\S)(.+?)(?<=\S)\*"#) { "<i>\($0[1])</i>" }
        s = replace(s, #"(?<![\w])_(?=\S)(.+?)(?<=\S)_(?![\w])"#) { "<i>\($0[1])</i>" }
        return s
    }

    private static func replace(_ s: String, _ pattern: String, _ f: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var result = "", last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var groups: [String] = []
            for g in 0..<m.numberOfRanges {
                let r = m.range(at: g)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            result += f(groups)
            last = m.range.location + m.range.length
        }
        return result + ns.substring(from: last)
    }
}
