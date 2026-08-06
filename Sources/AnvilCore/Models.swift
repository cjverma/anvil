import Foundation

public struct Preset: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var appBundleIDs: [String]
    public var appPaths: [String]
    public var domains: [String]
    public var defaultMinutes: Int

    public init(
        id: UUID = UUID(),
        name: String,
        appBundleIDs: [String] = [],
        appPaths: [String] = [],
        domains: [String] = [],
        defaultMinutes: Int
    ) {
        self.id = id
        self.name = name
        self.appBundleIDs = appBundleIDs
        self.appPaths = appPaths
        self.domains = domains
        self.defaultMinutes = defaultMinutes
    }
}

public struct Session: Codable, Equatable {
    public var startedAt: Date
    public var endsAt: Date
    public var preset: Preset

    public init(startedAt: Date, endsAt: Date, preset: Preset) {
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.preset = preset
    }

    public var isActive: Bool { endsAt > Date() }
}

public struct StartRequest: Codable, Equatable {
    public var preset: Preset
    public var minutes: Int

    public init(preset: Preset, minutes: Int) {
        self.preset = preset
        self.minutes = minutes
    }
}

public struct PublicState: Codable, Equatable {
    public var isActive: Bool
    public var endsAt: Date?
    public var presetName: String?

    public init(isActive: Bool, endsAt: Date?, presetName: String?) {
        self.isActive = isActive
        self.endsAt = endsAt
        self.presetName = presetName
    }
}

public enum RequestValidationError: Error, Equatable, LocalizedError {
    case invalidDuration
    case doesNotExtend
    case nothingToBlock

    public var errorDescription: String? {
        switch self {
        case .invalidDuration:
            return "Duration must be between 1 and 1440 minutes."
        case .doesNotExtend:
            return "Anvil only accepts requests that extend the current deadline."
        case .nothingToBlock:
            return "Add at least one app or website before starting a session."
        }
    }
}

public extension Preset {
    /// Nothing listed to block.
    ///
    /// Worth refusing rather than shrugging at: the escape tools are killed on
    /// every session regardless of preset, so starting an empty one closes your
    /// Terminal, Activity Monitor and System Settings for the full duration and
    /// blocks nothing at all in exchange. And there is no cancel.
    var blocksNothing: Bool {
        let normalized = self.normalized()
        return normalized.appBundleIDs.isEmpty
            && normalized.appPaths.isEmpty
            && normalized.domains.isEmpty
    }
}

public enum SessionPolicy {
    public static let maximumMinutes = 1_440

    public static func validatedSession(
        request: StartRequest,
        current: Session?,
        now: Date = Date()
    ) throws -> Session {
        guard (1...maximumMinutes).contains(request.minutes) else {
            throw RequestValidationError.invalidDuration
        }

        let candidateEnd = now.addingTimeInterval(TimeInterval(request.minutes * 60))
        if let current, current.endsAt > now {
            guard candidateEnd > current.endsAt else {
                throw RequestValidationError.doesNotExtend
            }
            return Session(
                startedAt: current.startedAt,
                endsAt: candidateEnd,
                preset: current.preset.union(request.preset)
            )
        }

        // Only a session starting from nothing needs something to block. An empty
        // preset against a live session is the natural way to say "same blocklist,
        // later deadline", and the union above already handles it.
        guard !request.preset.blocksNothing else {
            throw RequestValidationError.nothingToBlock
        }

        return Session(startedAt: now, endsAt: candidateEnd, preset: request.preset.normalized())
    }
}

public extension Preset {
    func normalized() -> Preset {
        Preset(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : name,
            appBundleIDs: Array(Set(appBundleIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted(),
            appPaths: Array(Set(appPaths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted(),
            domains: Array(Set(domains.map { DomainNormalizer.normalize($0) }.filter { !$0.isEmpty })).sorted(),
            defaultMinutes: min(max(defaultMinutes, 1), SessionPolicy.maximumMinutes)
        )
    }

    func union(_ other: Preset) -> Preset {
        let left = normalized()
        let right = other.normalized()
        return Preset(
            id: left.id,
            name: left.name,
            appBundleIDs: Array(Set(left.appBundleIDs + right.appBundleIDs)).sorted(),
            appPaths: Array(Set(left.appPaths + right.appPaths)).sorted(),
            domains: Array(Set(left.domains + right.domains)).sorted(),
            defaultMinutes: left.defaultMinutes
        )
    }
}

public enum DomainNormalizer {
    public static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let schemeRange = value.range(of: "://") {
            value = String(value[schemeRange.upperBound...])
        }
        value = value.split(separator: "/").first.map(String.init) ?? value
        value = value.split(separator: ":").first.map(String.init) ?? value
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        // Fold www. into the apex so "www.reddit.com" and "reddit.com" are one
        // entry. Left separate they never dedupe through Set, and the rendered
        // hosts block carries both plus a nonsense "www.www.reddit.com".
        if value.hasPrefix("www."), value.count > 4 {
            value = String(value.dropFirst(4))
        }
        return value
    }
}
