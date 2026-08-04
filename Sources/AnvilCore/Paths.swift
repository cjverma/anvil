import Foundation

public struct AnvilPaths {
    public var supportDirectory: URL
    public var socketPath: String
    public var launchDaemonDirectory: URL

    public init(
        supportDirectory: URL = URL(fileURLWithPath: "/Library/Application Support/Anvil", isDirectory: true),
        socketPath: String = "/var/run/anvil.sock",
        launchDaemonDirectory: URL = URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true)
    ) {
        self.supportDirectory = supportDirectory
        self.socketPath = socketPath
        self.launchDaemonDirectory = launchDaemonDirectory
    }

    public var sessionFile: URL { supportDirectory.appendingPathComponent("session.json") }
    public var publicStateFile: URL { supportDirectory.appendingPathComponent("public-state.json") }
    public var lockFile: URL { supportDirectory.appendingPathComponent("anvil.lock") }
    public var pfBackupFile: URL { supportDirectory.appendingPathComponent("pf.conf.orig") }
    public var policyBackupDirectory: URL { supportDirectory.appendingPathComponent("policy-backups", isDirectory: true) }
    /// Written only when Anvil is the one that turned pf on, so a session end does
    /// not disable a firewall the user was already running.
    public var pfWasOffMarker: URL { supportDirectory.appendingPathComponent("pf-was-off") }
    public var daemonPlist: URL { launchDaemonDirectory.appendingPathComponent("com.cjverma.anvild.plist") }
    public var watchdogPlist: URL { launchDaemonDirectory.appendingPathComponent("com.cjverma.anvil-watchdog.plist") }

    public static let userPresetsFile = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Anvil/presets.json")
}
