import Foundation

public final class SessionStore {
    private let paths: AnvilPaths

    public init(paths: AnvilPaths = AnvilPaths()) {
        self.paths = paths
    }

    public func current() -> Session? {
        guard FileManager.default.fileExists(atPath: paths.sessionFile.path) else { return nil }
        return try? JSONFiles.read(Session.self, from: paths.sessionFile)
    }

    public func startOrExtend(_ request: StartRequest, now: Date = Date()) throws -> Session {
        let session = try SessionPolicy.validatedSession(request: request, current: current(), now: now)
        try write(session)
        return session
    }

    public func write(_ session: Session) throws {
        try prepareSupportDirectory()
        try JSONFiles.write(session, to: paths.sessionFile, permissions: 0o600)
        try writePublicState(for: session)
    }

    public func clear() throws {
        try? FileManager.default.removeItem(at: paths.sessionFile)
        try JSONFiles.write(PublicState(isActive: false, endsAt: nil, presetName: nil), to: paths.publicStateFile, permissions: 0o644)
    }

    public func writePublicState(for session: Session) throws {
        let state = PublicState(isActive: session.endsAt > Date(), endsAt: session.endsAt, presetName: session.preset.name)
        try JSONFiles.write(state, to: paths.publicStateFile, permissions: 0o644)
    }

    private func prepareSupportDirectory() throws {
        try FileManager.default.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.supportDirectory.path)
    }
}
