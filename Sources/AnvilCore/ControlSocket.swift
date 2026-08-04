import Foundation

#if os(macOS)
import Darwin
#endif

public enum ControlSocketError: Error, LocalizedError {
    case socketCreationFailed
    case bindFailed
    case listenFailed
    case acceptFailed
    case payloadTooLarge
    case rateLimited

    public var errorDescription: String? {
        switch self {
        case .socketCreationFailed: return "Could not create UNIX socket."
        case .bindFailed: return "Could not bind UNIX socket."
        case .listenFailed: return "Could not listen on UNIX socket."
        case .acceptFailed: return "Could not accept UNIX socket connection."
        case .payloadTooLarge: return "Socket payload exceeds 4 KB."
        case .rateLimited: return "Start requests are rate-limited to one every five seconds."
        }
    }
}

public final class ControlSocketServer {
    public static let maxPayloadBytes = 4_096
    public static let minimumRequestInterval: TimeInterval = 5

    private let path: String
    private var fd: Int32 = -1
    private var lastAcceptedAt: Date?

    public init(path: String = AnvilPaths().socketPath) {
        self.path = path
    }

    deinit {
        if fd >= 0 { close(fd) }
    }

    public func start(onRequest: @escaping (StartRequest) -> String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlSocketError.socketCreationFailed }
        unlink(path)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxPath else { throw ControlSocketError.bindFailed }
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: CChar.self, repeating: 0)
            _ = path.withCString { source in
                strncpy(rawBuffer.baseAddress!.assumingMemoryBound(to: CChar.self), source, maxPath - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { throw ControlSocketError.bindFailed }
        chmod(path, 0o622)
        guard listen(fd, 8) == 0 else { throw ControlSocketError.listenFailed }

        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { throw ControlSocketError.acceptFailed }
            handle(client: client, onRequest: onRequest)
            close(client)
        }
    }

    private func handle(client: Int32, onRequest: (StartRequest) -> String) {
        do {
            if let lastAcceptedAt, Date().timeIntervalSince(lastAcceptedAt) < Self.minimumRequestInterval {
                throw ControlSocketError.rateLimited
            }

            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 512)
            while true {
                let count = read(client, &buffer, buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
                if data.count > Self.maxPayloadBytes {
                    throw ControlSocketError.payloadTooLarge
                }
            }

            lastAcceptedAt = Date()
            let request = try JSONFiles.decoder.decode(StartRequest.self, from: data)
            try writeResponse(onRequest(request), to: client)
        } catch {
            try? writeResponse("error: \(error.localizedDescription)", to: client)
        }
    }

    private func writeResponse(_ response: String, to client: Int32) throws {
        let bytes = Array((response + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(client, $0.baseAddress, bytes.count) }
    }
}

public struct ControlSocketClient {
    public var path: String

    public init(path: String = AnvilPaths().socketPath) {
        self.path = path
    }

    public func send(_ request: StartRequest) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlSocketError.socketCreationFailed }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: CChar.self, repeating: 0)
            _ = path.withCString { source in
                strncpy(rawBuffer.baseAddress!.assumingMemoryBound(to: CChar.self), source, maxPath - 1)
            }
        }

        let result = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw ControlSocketError.acceptFailed }

        let data = try JSONFiles.encoder.encode(request)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        shutdown(fd, SHUT_WR)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            response.append(buffer, count: count)
        }
        return String(data: response, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
