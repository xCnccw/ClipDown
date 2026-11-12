import Foundation
import CryptoKit

public struct ClipItem: Codable, Identifiable, Equatable {
    public enum Kind: String, Codable { case text, image, file }

    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var text: String?
    public var html: String?
    public var rtf: Data?
    public var imageFile: String?
    public var imageKey: String?
    public var sourceApp: String?
    public var pinned: Bool
    public var sourceBundleID: String?
    public var boardID: UUID?

    public init(id: UUID = UUID(), date: Date = Date(), kind: Kind, text: String? = nil,
                html: String? = nil, rtf: Data? = nil, imageFile: String? = nil,
                imageKey: String? = nil, sourceApp: String? = nil, pinned: Bool = false,
                sourceBundleID: String? = nil, boardID: UUID? = nil) {
        self.id = id; self.date = date; self.kind = kind; self.text = text
        self.html = html; self.rtf = rtf; self.imageFile = imageFile
        self.imageKey = imageKey; self.sourceApp = sourceApp; self.pinned = pinned
        self.sourceBundleID = sourceBundleID; self.boardID = boardID
    }

    /// Identity used for de-duplication.
    public var key: String {
        switch kind {
        case .text: return "t:" + (text ?? "")
        case .image: return "i:" + (imageKey ?? id.uuidString)
        case .file: return "f:" + (text ?? "")
        }
    }

    public var isRich: Bool { html != nil || rtf != nil }

    public static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public extension ClipItem {
    var filePaths: [String] { kind == .file ? (text ?? "").components(separatedBy: "\n").filter { !$0.isEmpty } : [] }
    var linkURL: URL? {
        guard kind == .text, let t = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.contains(" "), !t.contains("\n"), let u = URL(string: t),
              ["http", "https"].contains(u.scheme?.lowercased() ?? ""), u.host != nil else { return nil }
        return u
    }
}

public struct Board: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var colorHex: String
    public init(id: UUID = UUID(), name: String, colorHex: String) { self.id = id; self.name = name; self.colorHex = colorHex }
}
