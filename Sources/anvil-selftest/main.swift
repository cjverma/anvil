import AnvilCore
import Foundation

enum SelfTest {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func expectThrows(_ message: String, _ body: () throws -> Void) {
        do {
            try body()
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        } catch {}
    }
}

let hosts = HostsFile(path: URL(fileURLWithPath: "/tmp/hosts"))
let existingHosts = "127.0.0.1 localhost\n# user line\n"
let once = hosts.blockedContents(existing: existingHosts, domains: ["YouTube.com"])
let twice = hosts.blockedContents(existing: once, domains: ["youtube.com"])
SelfTest.expect(once == twice, "hosts rewrite is idempotent")
SelfTest.expect(once.contains("# user line"), "hosts preserves user lines")
SelfTest.expect(once.contains("0.0.0.0 youtube.com"), "hosts blocks apex")
SelfTest.expect(once.contains(":: www.youtube.com"), "hosts blocks www IPv6")

let duplicated = "a\n# >>> anvil\nbad\n# <<< anvil\nb\n# >>> anvil\nbad2\n# <<< anvil\nc"
SelfTest.expect(hosts.removeManagedSection(from: duplicated) == "a\nb\nc\n", "hosts removes duplicate managed sections")

let now = Date(timeIntervalSince1970: 100)
let preset = Preset(name: "Deep", domains: ["example.com"], defaultMinutes: 30)
let current = Session(startedAt: now, endsAt: now.addingTimeInterval(60 * 60), preset: preset)
SelfTest.expectThrows("deadline rejects shortening") {
    _ = try SessionPolicy.validatedSession(request: StartRequest(preset: preset, minutes: 30), current: current, now: now)
}
let extended = try SessionPolicy.validatedSession(
    request: StartRequest(preset: Preset(name: "More", domains: ["reddit.com"], defaultMinutes: 90), minutes: 90),
    current: current,
    now: now
)
SelfTest.expect(extended.endsAt == now.addingTimeInterval(90 * 60), "deadline extends")
SelfTest.expect(Set(extended.preset.domains) == ["example.com", "reddit.com"], "session unions blocklists")
SelfTest.expectThrows("duration rejects zero") {
    _ = try SessionPolicy.validatedSession(request: StartRequest(preset: preset, minutes: 0), current: nil)
}
SelfTest.expectThrows("duration rejects over cap") {
    _ = try SessionPolicy.validatedSession(request: StartRequest(preset: preset, minutes: 1_441), current: nil)
}

SelfTest.expect(ControlSocketServer.maxPayloadBytes == 4_096, "socket payload cap")
SelfTest.expect(ControlSocketServer.minimumRequestInterval == 5, "socket rate limit")

let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
    .appendingPathComponent("Slack2.app")
let info = root.appendingPathComponent("Contents/Info.plist")
try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
NSDictionary(dictionary: ["CFBundleIdentifier": "com.tinyspeck.slackmacgap"]).write(to: info, atomically: true)
defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
let executable = root.appendingPathComponent("Contents/MacOS/Slack").path
SelfTest.expect(ProcessScanner().bundleID(forExecutablePath: executable) == "com.tinyspeck.slackmacgap", "bundle ID from renamed app")

let scanner = ProcessScanner()
let terminal = RunningProcess(
    pid: 500,
    executablePath: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
    commandLine: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
    uid: getuid(),
    bundleID: "com.apple.Terminal"
)
let dock = RunningProcess(
    pid: 501,
    executablePath: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",
    commandLine: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",
    uid: getuid(),
    bundleID: "com.apple.dock"
)
SelfTest.expect(scanner.shouldKill(terminal, preset: Preset(name: "None", defaultMinutes: 15)), "Terminal is killable")
SelfTest.expect(!scanner.shouldKill(dock, preset: Preset(name: "None", defaultMinutes: 15)), "Dock is protected")

let pf = PFAnchor(anchorPath: URL(fileURLWithPath: "/etc/pf.anchors/anvil"))
let basePF = "scrub-anchor \"com.apple/*\"\n"
let anchoredPF = pf.pfConfWithAnchor(existing: basePF)
SelfTest.expect(anchoredPF.contains("anchor \"anvil\""), "pf anchor inserted")
SelfTest.expect(pf.removeManagedSection(from: anchoredPF) == basePF, "pf anchor removed")

print("Anvil self-test passed")
