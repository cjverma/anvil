import AnvilCore
import Foundation
import Darwin

struct Options {
    var dryRun = false
    var testMode = false
}

let options = Options(
    dryRun: CommandLine.arguments.contains("--dry-run"),
    testMode: CommandLine.arguments.contains("--test-mode")
)

signal(SIGTERM, SIG_IGN)
signal(SIGHUP, SIG_IGN)
signal(SIGINT, SIG_IGN)

let paths = AnvilPaths()
let store = SessionStore(paths: paths)
let hosts = HostsFile()
let pf = PFAnchor()
let browserPolicy = BrowserPolicy()
let scanner = ProcessScanner()

func ensureSingleInstance() {
    try? FileManager.default.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
    let fd = open(paths.lockFile.path, O_CREAT | O_RDWR, 0o600)
    if fd >= 0, flock(fd, LOCK_EX | LOCK_NB) != 0 {
        print("[anvild] another instance is already running")
        exit(0)
    }
}

func enforce(session: Session, includeEscapeTools: Bool = true, configurePF: Bool = true) {
    let preset = options.testMode
        ? Preset(name: "Anvil Test", domains: ["example.invalid"], defaultMinutes: 2)
        : session.preset

    scanner.enforce(preset: preset, dryRun: options.dryRun, includeEscapeTools: includeEscapeTools)
    try? hosts.apply(domains: preset.domains, dryRun: options.dryRun)
    browserPolicy.apply(dryRun: options.dryRun)
    if configurePF {
        pf.enable(domains: preset.domains, dryRun: options.dryRun)
    }
}

func cleanup() {
    try? hosts.clear(dryRun: options.dryRun)
    browserPolicy.clear(dryRun: options.dryRun)
    pf.disable(dryRun: options.dryRun)
    try? store.clear()
}

ensureSingleInstance()

if options.dryRun {
    let session = store.current() ?? Session(
        startedAt: Date(),
        endsAt: Date().addingTimeInterval(15 * 60),
        preset: Preset(name: "Dry Run", domains: ["example.com"], defaultMinutes: 15)
    )
    print("[anvild] dry-run: no files will be changed and no processes will be killed")
    enforce(session: session)
    exit(0)
}

if options.testMode {
    let session = Session(
        startedAt: Date(),
        endsAt: Date().addingTimeInterval(120),
        preset: Preset(name: "Anvil Test", domains: ["example.invalid"], defaultMinutes: 2)
    )
    try? store.write(session)
    browserPolicy.purgeRunningBrowsers(dryRun: false)
}

DispatchQueue.global(qos: .userInitiated).async {
    do {
        try ControlSocketServer(path: paths.socketPath).start { request in
            do {
                let session = try store.startOrExtend(request)
                browserPolicy.purgeRunningBrowsers()
                enforce(session: session)
                return "ok: active until \(ISO8601DateFormatter().string(from: session.endsAt))"
            } catch {
                return "error: \(error.localizedDescription)"
            }
        }
    } catch {
        print("[anvild] socket failed: \(error)")
        exit(1)
    }
}

var lastPFRefresh = Date.distantPast
// Cleanup runs once on the active-to-idle transition, not on every idle tick.
//
// Calling it every second while nothing is blocked meant restoring browser
// policies, flushing pf and rewriting public state once a second forever: a
// couple of process spawns per second at rest, and repeated churn over files
// that are already in their final state.
//
// Starts true so a daemon coming up with no active session performs exactly one
// cleanup pass. That is the crash-recovery path: if the last session died between
// its deadline and its revert, /etc/hosts and the pf anchor are still in place.
var wasEnforcing = true

while true {
    autoreleasepool {
        guard let session = store.current(), session.endsAt > Date() else {
            if wasEnforcing {
                wasEnforcing = false
                lastPFRefresh = .distantPast
                cleanup()
            }
            sleep(1)
            return
        }

        wasEnforcing = true
        enforce(session: session, includeEscapeTools: !options.testMode, configurePF: false)
        try? store.writePublicState(for: session)

        if Date().timeIntervalSince(lastPFRefresh) > 300 {
            if lastPFRefresh == .distantPast {
                pf.enable(domains: session.preset.domains, dryRun: options.dryRun)
            } else {
                pf.replaceTable(domains: session.preset.domains)
            }
            lastPFRefresh = Date()
        }
        sleep(1)
    }
}
