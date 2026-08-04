import XCTest
@testable import AnvilCore

final class ProcessScannerTests: XCTestCase {
    let scanner = ProcessScanner()

    func process(
        pid: Int32 = 5_000,
        uid: UInt32 = 501,
        path: String,
        command: String? = nil,
        bundleID: String?
    ) -> RunningProcess {
        RunningProcess(
            pid: pid,
            executablePath: path,
            commandLine: command ?? path,
            uid: uid,
            bundleID: bundleID
        )
    }

    // MARK: - ps parsing
    //
    // Regression tests for the parse that split "pid comm command" on the first
    // space. Every one of these paths contains a space, and the old parser cut them
    // at the first one, which left no .app component, which meant no bundle ID, which
    // meant bundle-ID matching silently stopped working for exactly these apps.

    func testExecutablePathsWithSpacesSurviveParsing() {
        let cases = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/System/Applications/Utilities/Activity Monitor.app/Contents/MacOS/Activity Monitor",
            "/System/Applications/System Settings.app/Contents/MacOS/System Settings",
            "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
        ]
        for path in cases {
            let parsed = scanner.parseProcessLine("  501   502 \(path)")
            XCTAssertEqual(parsed?.pid, 501)
            XCTAssertEqual(parsed?.uid, 502)
            XCTAssertEqual(parsed?.executablePath, path, "path was truncated at a space")
        }
    }

    func testCommandLineIsJoinedOnPID() {
        let parsed = scanner.parseProcessLine(
            "700 501 /Applications/Slack.app/Contents/MacOS/Slack",
            commandsByPID: [700: "/Applications/Slack.app/Contents/MacOS/Slack --startup"]
        )
        XCTAssertEqual(parsed?.commandLine, "/Applications/Slack.app/Contents/MacOS/Slack --startup")
    }

    func testCommandLineFallsBackToPathWhenTheSecondPassMissesIt() {
        // A process can exit between the two ps calls.
        let parsed = scanner.parseProcessLine("700 501 /Applications/Slack.app/Contents/MacOS/Slack")
        XCTAssertEqual(parsed?.commandLine, "/Applications/Slack.app/Contents/MacOS/Slack")
    }

    func testSplitLeadingIntegerHandlesPaddingAndTabs() {
        XCTAssertEqual(ProcessScanner.splitLeadingInteger("  42  rest of it")?.0, 42)
        XCTAssertEqual(ProcessScanner.splitLeadingInteger("  42  rest of it")?.1, "rest of it")
        XCTAssertNil(ProcessScanner.splitLeadingInteger(""))
        XCTAssertNil(ProcessScanner.splitLeadingInteger("nonumber"))
        XCTAssertNil(ProcessScanner.splitLeadingInteger("not a number"))
    }

    func testMalformedLinesAreDroppedRatherThanGuessed() {
        XCTAssertNil(scanner.parseProcessLine(""))
        XCTAssertNil(scanner.parseProcessLine("501"))
        XCTAssertNil(scanner.parseProcessLine("501 502 "))
    }

    // MARK: - The guard pair
    //
    // These fail in opposite directions: a guard list broad enough to cover
    // /System/Applications silently disables escape-tool blocking, and one that
    // misses a system service lets the daemon log you out.

    func testTerminalIsKillableAndDockIsNot() {
        let empty = Preset(name: "None", defaultMinutes: 15)
        let terminal = process(
            path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
            bundleID: "com.apple.Terminal"
        )
        let dock = process(
            path: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",
            bundleID: "com.apple.dock"
        )
        XCTAssertTrue(scanner.shouldKill(terminal, preset: empty))
        XCTAssertFalse(scanner.shouldKill(dock, preset: empty))
    }

    func testSystemApplicationsIsNotTreatedAsAProtectedPrefix() {
        // Terminal, Activity Monitor and System Settings all live under
        // /System/Applications on macOS 13+.
        XCTAssertFalse(
            ProcessScanner.protectedPathPrefixes.contains { "/System/Applications/".hasPrefix($0) },
            "a /System/ prefix here turns escape-tool blocking into a no-op"
        )
    }

    func testEscapeToolsAndProtectedListsDoNotOverlap() {
        let overlap = Set(ProcessScanner.escapeTools.appBundleIDs)
            .intersection(ProcessScanner.protectedBundleIDs)
        XCTAssertTrue(overlap.isEmpty, "an escape tool that is also protected can never be killed: \(overlap)")
    }

    func testSystemServicesAndRootProcessesAreProtected() {
        let preset = Preset(name: "Everything", appPaths: ["/"], defaultMinutes: 15)
        let cases: [(String, String?, UInt32, Int32)] = [
            ("/usr/libexec/secinitd", nil, 501, 5_000),
            ("/usr/sbin/cfprefsd", nil, 501, 5_000),
            ("/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow", nil, 501, 5_000),
            ("/sbin/launchd", nil, 0, 1),
            ("/Applications/Slack.app/Contents/MacOS/Slack", "com.tinyspeck.slackmacgap", 501, 42),
            // Root-owned covers Anvil's own daemons, which must never kill themselves.
            ("/Library/Application Support/Anvil/bin/anvild", nil, 0, 9_000),
        ]
        for (path, bundleID, uid, pid) in cases {
            let running = process(pid: pid, uid: uid, path: path, bundleID: bundleID)
            XCTAssertFalse(scanner.shouldKill(running, preset: preset), "\(path) must be protected")
        }
    }

    func testEveryProtectedBundleIDIsProtectedRegardlessOfPath() {
        let preset = Preset(name: "Everything", appPaths: ["/Applications/"], defaultMinutes: 15)
        for bundleID in ProcessScanner.protectedBundleIDs {
            let running = process(path: "/Applications/Whatever.app/Contents/MacOS/W", bundleID: bundleID)
            XCTAssertFalse(scanner.shouldKill(running, preset: preset), "\(bundleID) must be protected")
        }
    }

    // MARK: - Matching

    func testBundleIDMatchesThroughRenamingAndRelocation() {
        let preset = Preset(name: "P", appBundleIDs: ["com.tinyspeck.slackmacgap"], defaultMinutes: 15)
        let disguises = [
            "/Applications/Slack2.app/Contents/MacOS/Slack",
            "/tmp/Definitely Not Slack.app/Contents/MacOS/Slack",
            "/Users/me/Applications/Slack.app/Contents/MacOS/Slack",
        ]
        for path in disguises {
            let running = process(path: path, bundleID: "com.tinyspeck.slackmacgap")
            XCTAssertTrue(scanner.shouldKill(running, preset: preset), "should still match \(path)")
        }
    }

    func testUnrelatedProcessesAreLeftAlone() {
        let preset = Preset(
            name: "P",
            appBundleIDs: ["com.tinyspeck.slackmacgap"],
            appPaths: ["/Applications/Slack.app"],
            defaultMinutes: 15
        )
        let running = process(path: "/Applications/Xcode.app/Contents/MacOS/Xcode", bundleID: "com.apple.dt.Xcode")
        XCTAssertFalse(scanner.shouldKill(running, preset: preset))
    }

    func testEscapeToolsAreSkippedWhenExcluded() {
        let preset = Preset(name: "P", domains: ["reddit.com"], defaultMinutes: 15)
        let terminal = process(
            path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
            bundleID: "com.apple.Terminal"
        )
        XCTAssertTrue(scanner.shouldKill(terminal, preset: preset, includeEscapeTools: true))
        XCTAssertFalse(
            scanner.shouldKill(terminal, preset: preset, includeEscapeTools: false),
            "test mode has to leave the shell alone"
        )
    }

    func testThirdPartyTerminalsCount() {
        let preset = Preset(name: "P", domains: ["reddit.com"], defaultMinutes: 15)
        // Leaving any one of these out hands back a root shell.
        for bundleID in ["dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "io.alacritty", "com.github.wez.wezterm"] {
            let running = process(path: "/Applications/Term.app/Contents/MacOS/Term", bundleID: bundleID)
            XCTAssertTrue(scanner.shouldKill(running, preset: preset), "\(bundleID) should be treated as an escape tool")
        }
    }
}
