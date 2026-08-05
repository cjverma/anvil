import AnvilCore
import Foundation
import Darwin

signal(SIGTERM, SIG_IGN)
signal(SIGHUP, SIG_IGN)
signal(SIGINT, SIG_IGN)

let paths = AnvilPaths()

/// Asks launchd about the job rather than grepping `ps`.
///
/// Two reasons. `ps -axww -o command=` walks every process on the machine and
/// returns tens of kilobytes, once a second, forever — it made this process burn
/// roughly two hundred times the CPU of the daemon it watches. And a substring
/// match on "anvild" also matches "sudo .build/release/anvild --dry-run", so a
/// leftover rehearsal process would convince the watchdog the daemon was alive
/// when it was not, which defeats the point of having one.
///
/// Output is captured and discarded: `launchctl print` is verbose, and letting it
/// inherit stdout would pour it into the daemon's log file every second.
func jobIsLoaded(label: String) -> Bool {
    Shell.output("/bin/launchctl", ["print", "system/\(label)"]) != nil
}

func writePlistIfNeeded(_ plist: URL, contents: String) {
    guard (try? String(contentsOf: plist, encoding: .utf8)) != contents else { return }
    do {
        try contents.write(to: plist, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plist.path)
    } catch {
        print("[anvil-watchdog] could not write \(plist.path): \(error)")
    }
}

func heal(label: String, plist: URL, contents: String) {
    writePlistIfNeeded(plist, contents: contents)
    _ = Shell.run("/bin/launchctl", ["bootstrap", "system", plist.path])
    _ = Shell.run("/bin/launchctl", ["kickstart", "-k", "system/\(label)"])
}

let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let daemonExecutable = executableDirectory.appendingPathComponent("anvild").path
let watchdogExecutable = executableDirectory.appendingPathComponent("anvil-watchdog").path

while true {
    autoreleasepool {
        if !jobIsLoaded(label: "com.cjverma.anvild") {
            heal(
                label: "com.cjverma.anvild",
                plist: paths.daemonPlist,
                contents: LaunchDaemonPlists.daemon(executablePath: daemonExecutable)
            )
        }

        // No process check for ourselves: this code is running, so the answer is
        // always yes, and asking cost a second full process scan every second.
        //
        // The plist is a different matter. It can be deleted while we keep running,
        // and without it the watchdog never comes back after a reboot. Comparing a
        // small file costs nothing next to spawning a process.
        writePlistIfNeeded(
            paths.watchdogPlist,
            contents: LaunchDaemonPlists.watchdog(executablePath: watchdogExecutable)
        )

        sleep(1)
    }
}
