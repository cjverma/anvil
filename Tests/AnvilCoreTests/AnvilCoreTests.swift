import XCTest
@testable import AnvilCore

final class AnvilCoreTests: XCTestCase {
    func testHostsSectionIsIdempotentAndPreservesUserLines() {
        let hosts = HostsFile(path: URL(fileURLWithPath: "/tmp/hosts"))
        let existing = """
        127.0.0.1 localhost
        # user line

        """

        let once = hosts.blockedContents(existing: existing, domains: ["YouTube.com"])
        let twice = hosts.blockedContents(existing: once, domains: ["youtube.com"])

        XCTAssertEqual(once, twice)
        XCTAssertTrue(once.contains("127.0.0.1 localhost"))
        XCTAssertTrue(once.contains("# user line"))
        XCTAssertTrue(once.contains("0.0.0.0 youtube.com"))
        XCTAssertTrue(once.contains(":: www.youtube.com"))
    }

    func testHostsRemovesDuplicatedManagedSections() {
        let hosts = HostsFile()
        let existing = """
        a
        # >>> anvil
        bad
        # <<< anvil
        b
        # >>> anvil
        bad2
        # <<< anvil
        c
        """
        XCTAssertEqual(hosts.removeManagedSection(from: existing), "a\nb\nc\n")
    }

    func testDeadlineOnlyExtends() throws {
        let now = Date(timeIntervalSince1970: 100)
        let preset = Preset(name: "Deep", domains: ["example.com"], defaultMinutes: 30)
        let current = Session(startedAt: now, endsAt: now.addingTimeInterval(60 * 60), preset: preset)

        XCTAssertThrowsError(try SessionPolicy.validatedSession(
            request: StartRequest(preset: preset, minutes: 30),
            current: current,
            now: now
        ))

        let extended = try SessionPolicy.validatedSession(
            request: StartRequest(preset: Preset(name: "More", domains: ["reddit.com"], defaultMinutes: 90), minutes: 90),
            current: current,
            now: now
        )
        XCTAssertEqual(extended.endsAt, now.addingTimeInterval(90 * 60))
        XCTAssertEqual(Set(extended.preset.domains), ["example.com", "reddit.com"])
    }

    func testDurationValidation() {
        let preset = Preset(name: "Deep", defaultMinutes: 30)
        XCTAssertThrowsError(try SessionPolicy.validatedSession(request: StartRequest(preset: preset, minutes: 0), current: nil))
        XCTAssertThrowsError(try SessionPolicy.validatedSession(request: StartRequest(preset: preset, minutes: 1_441), current: nil))
    }

    func testPayloadLimitConstant() {
        XCTAssertEqual(ControlSocketServer.maxPayloadBytes, 4_096)
        XCTAssertEqual(ControlSocketServer.minimumRequestInterval, 5)
    }

    func testBundleExtractionFromRenamedAppPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Slack2.app")
        let info = root.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        NSDictionary(dictionary: ["CFBundleIdentifier": "com.tinyspeck.slackmacgap"]).write(to: info, atomically: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let executable = root.appendingPathComponent("Contents/MacOS/Slack").path
        XCTAssertEqual(ProcessScanner().bundleID(forExecutablePath: executable), "com.tinyspeck.slackmacgap")
    }

    func testTerminalKillableButDockProtected() {
        let scanner = ProcessScanner()
        let preset = Preset(name: "None", defaultMinutes: 15)

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

        XCTAssertTrue(scanner.shouldKill(terminal, preset: preset))
        XCTAssertFalse(scanner.shouldKill(dock, preset: preset))
    }

    func testPFAnchorInsertionAndRemoval() {
        let pf = PFAnchor(anchorPath: URL(fileURLWithPath: "/etc/pf.anchors/anvil"))
        let existing = "scrub-anchor \"com.apple/*\"\n"
        let withAnchor = pf.pfConfWithAnchor(existing: existing)
        XCTAssertTrue(withAnchor.contains("anchor \"anvil\""))
        XCTAssertEqual(pf.removeManagedSection(from: withAnchor), existing)
    }
}
