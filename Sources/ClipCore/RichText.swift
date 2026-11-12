import AppKit

public enum RichText {
    /// Convert an HTML string to RTF data using Cocoa's importer.
    public static func rtf(fromHTML html: String) -> Data? {
        guard let data = html.data(using: .utf8),
              let attr = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil)
        else { return nil }
        return try? attr.data(from: NSRange(location: 0, length: attr.length),
                              documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    public static func attributed(from item: ClipItem) -> NSAttributedString? {
        if let r = item.rtf, let a = try? NSAttributedString(data: r, options: [:], documentAttributes: nil) { return a }
        return nil
    }
}
