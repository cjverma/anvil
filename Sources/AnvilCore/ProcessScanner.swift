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
            "com.apple.ScriptEditor2",
            // Third-party terminals are the same escape hatch as Terminal.app.
            // Leaving any one of them out hands back a root shell.
            "dev.warp.Warp-Stable",
            "co.zeit.hyper",
            "net.kovidgoyal.kitty",
            "io.alacritty",
            "com.github.wez.wezterm",
            "com.mitchellh.ghostty"
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

    /// Two `ps` passes joined on pid.
    ///
    /// `comm` and `command` can each contain spaces and `ps` gives no delimiter to
    /// say where one ends and the next begins, so only the trailing column can be
    /// parsed safely. Asking for both in one call and splitting on the first space
    /// turns "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" into
    /// "/Applications/Google", which has no .app component — so the bundle lookup
    /// returns nil and bundle-ID matching silently stops working for every app with
    /// a space in its name.
    ///
    /// `uid` rides along in the same call. Querying it per pid costs one `ps` fork
    /// per process per tick: several hundred a second, forever, as root.
    public func runningProcesses() -> [RunningProcess] {
        guard let identity = Shell.output("/bin/ps", ["-axww", "-o", "pid=,uid=,comm="]) else { return [] }
        let commands = Shell.output("/bin/ps", ["-axww", "-o", "pid=,command="]) ?? ""

        var commandsByPID: [Int32: String] = [:]
        for line in commands.split(separator: "\n") {
            guard let (pid, rest) = Self.splitLeadingInteger(String(line)) else { continue }
            commandsByPID[pid] = rest
        }

        return identity.split(separator: "\n").compactMap { line in
            parseProcessLine(String(line), commandsByPID: commandsByPID)
        }
    }

    public func parseProcessLine(_ line: String, commandsByPID: [Int32: String] = [:]) -> RunningProcess? {
        guard let (pid, afterPID) = Self.splitLeadingInteger(line),
              let (uid, executablePath) = Self.splitLeadingInteger(afterPID) else { return nil }
        let path = executablePath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        return RunningProcess(
            pid: pid,
            executablePath: path,
            commandLine: commandsByPID[pid] ?? path,
            uid: UInt32(max(0, uid)),
            bundleID: bundleID(forExecutablePath: path)
        )
    }

    /// Peels one integer field off the front of a line and returns the remainder
    /// untouched, so a trailing path keeps its spaces.
    static func splitLeadingInteger(_ line: String) -> (Int32, String)? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard let boundary = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
        guard let value = Int32(trimmed[trimmed.startIndex..<boundary]) else { return nil }
        let rest = trimmed[trimmed.index(after: boundary)...].drop { $0 == " " || $0 == "\t" }
        return (value, String(rest))
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

}
