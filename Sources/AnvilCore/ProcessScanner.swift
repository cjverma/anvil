import Foundation

public struct RunningProcess: Equatable {
    public var pid: Int32
    public var executablePath: String
    public var commandLine: String
    public var uid: UInt32
    public var bundleID: String?

    public init(pid: Int32, executablePath: String, commandLine: String, uid: UInt32 = getuid(), bundleID: String? = nil) {
        self.pid = pid
        self.executablePath = executablePath
        self.commandLine = commandLine
        self.uid = uid
        self.bundleID = bundleID
    }
}

public struct ProcessScanner {
    public static let protectedBundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.WindowServer",
        "com.apple.loginwindow",
        "com.apple.systemuiserver"
    ]

    public static let protectedPathPrefixes = [
        "/System/Library/",
        "/usr/libexec/",
        "/usr/sbin/",
        "/usr/bin/",
        "/sbin/"
    ]

    public static let escapeTools = Preset(
        name: "Escape Tools",
        appBundleIDs: [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.apple.ActivityMonitor",
            "com.apple.systempreferences",
            "com.apple.SystemSettings",
            "com.apple.Console",
            "com.apple.ScriptEditor2"
        ],
        appPaths: [
            "/System/Applications/Utilities/Terminal.app",
            "/Applications/iTerm.app",
            "/System/Applications/Utilities/Activity Monitor.app",
            "/System/Applications/System Settings.app",
            "/Applications/System Preferences.app",
            "/System/Applications/Utilities/Console.app",
            "/System/Applications/Utilities/Script Editor.app"
        ],
        domains: [],
        defaultMinutes: 15
    )

    public init() {}

    public func runningProcesses() -> [RunningProcess] {
        guard let output = Shell.output("/bin/ps", ["-axww", "-o", "pid=,comm=,command="]) else { return [] }
        return output.split(separator: "\n").compactMap { line in
            parsePSLine(String(line))
        }
    }

    public func parsePSLine(_ line: String) -> RunningProcess? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let firstSpace = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
        let pidPart = String(trimmed[..<firstSpace])
        guard let pid = Int32(pidPart) else { return nil }
        let remainder = trimmed[firstSpace...].trimmingCharacters(in: .whitespaces)
        let pieces = remainder.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let comm = pieces.first else { return nil }
        let command = pieces.count > 1 ? String(pieces[1]) : String(comm)
        let path = String(comm)
        return RunningProcess(pid: pid, executablePath: path, commandLine: command, uid: uidForPID(pid), bundleID: bundleID(forExecutablePath: path))
    }

    public func shouldKill(_ process: RunningProcess, preset: Preset, includeEscapeTools: Bool = true) -> Bool {
        guard !isProtected(process) else { return false }
        let combined = includeEscapeTools ? preset.union(Self.escapeTools) : preset.normalized()
        let path = process.executablePath
        let argv = process.commandLine

        if let bundleID = process.bundleID, combined.appBundleIDs.contains(bundleID) {
            return true
        }
        if combined.appBundleIDs.contains(where: { argv.contains($0) }) {
            return true
        }
        if combined.appPaths.contains(where: { path.hasPrefix($0) || argv.contains($0) }) {
            return true
        }
        return false
    }

    public func enforce(preset: Preset, dryRun: Bool = false, includeEscapeTools: Bool = true) {
        for process in runningProcesses() where shouldKill(process, preset: preset, includeEscapeTools: includeEscapeTools) {
            if dryRun {
                print("[dry-run] would kill pid \(process.pid): \(process.bundleID ?? "no-bundle") \(process.executablePath)")
            } else {
                kill(process.pid, SIGTERM)
                usleep(150_000)
                kill(process.pid, SIGKILL)
            }
        }
    }

    public func isProtected(_ process: RunningProcess) -> Bool {
        if process.pid < 100 { return true }
        if process.uid == 0 { return true }
        if let bundleID = process.bundleID, Self.protectedBundleIDs.contains(bundleID) { return true }
        if Self.protectedPathPrefixes.contains(where: { process.executablePath.hasPrefix($0) }) { return true }
        return false
    }

    public func bundleID(forExecutablePath path: String) -> String? {
        guard let appRoot = appBundleRoot(containing: path) else { return nil }
        let info = URL(fileURLWithPath: appRoot).appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: info) as? [String: Any] else { return nil }
        return dict["CFBundleIdentifier"] as? String
    }

    public func appBundleRoot(containing path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        var current = ""
        for part in parts {
            if part.isEmpty {
                current = "/"
            } else if current == "/" {
                current += part
            } else {
                current += "/\(part)"
            }
            if current.hasSuffix(".app") {
                return current
            }
        }
        return nil
    }

    private func uidForPID(_ pid: Int32) -> UInt32 {
        let output = Shell.output("/bin/ps", ["-o", "uid=", "-p", "\(pid)"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return UInt32(output ?? "") ?? getuid()
    }
}
