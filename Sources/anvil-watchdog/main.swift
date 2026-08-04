import AnvilCore
import Foundation
import Darwin

signal(SIGTERM, SIG_IGN)
signal(SIGHUP, SIG_IGN)
signal(SIGINT, SIG_IGN)

let paths = AnvilPaths()

func processIsRunning(named name: String) -> Bool {
    let output = Shell.output("/bin/ps", ["-axww", "-o", "command="]) ?? ""
    return output.split(separator: "\n").contains { $0.contains(name) }
}

func bootstrap(label: String, plist: URL, contents: String) {
    do {
        if (try? String(contentsOf: plist, encoding: .utf8)) != contents {
            try contents.write(to: plist, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plist.path)
        }
        _ = Shell.run("/bin/launchctl", ["bootstrap", "system", plist.path])
        _ = Shell.run("/bin/launchctl", ["kickstart", "-k", "system/\(label)"])
    } catch {
        print("[anvil-watchdog] could not heal \(label): \(error)")
    }
}

let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let daemonExecutable = executableDirectory.appendingPathComponent("anvild").path
let watchdogExecutable = executableDirectory.appendingPathComponent("anvil-watchdog").path

while true {
    autoreleasepool {
        if !processIsRunning(named: "anvild") {
            bootstrap(
                label: "com.cjverma.anvild",
                plist: paths.daemonPlist,
                contents: LaunchDaemonPlists.daemon(executablePath: daemonExecutable)
            )
        }

        if !processIsRunning(named: "anvil-watchdog") {
            bootstrap(
                label: "com.cjverma.anvil-watchdog",
                plist: paths.watchdogPlist,
                contents: LaunchDaemonPlists.watchdog(executablePath: watchdogExecutable)
            )
        }
        sleep(1)
    }
}
