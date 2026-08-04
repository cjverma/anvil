import Foundation

public enum JSONFiles {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decoder.decode(T.self, from: Data(contentsOf: url))
    }

    public static func write<T: Encodable>(_ value: T, to url: URL, permissions: UInt16? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        try data.write(to: temporary, options: .atomic)
        if let permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }
}
