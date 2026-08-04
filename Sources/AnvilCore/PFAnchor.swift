import Foundation

public struct PFAnchor {
    public static let anchorName = "anvil"
    public static let tableName = "anvil_blocked"
    public static let markerStart = "# >>> anvil"
    public static let markerEnd = "# <<< anvil"

    public var pfConfPath: URL
    public var anchorPath: URL
    public var backupPath: URL

    public init(
        pfConfPath: URL = URL(fileURLWithPath: "/etc/pf.conf"),
        anchorPath: URL = URL(fileURLWithPath: "/etc/pf.anchors/anvil"),
        backupPath: URL = AnvilPaths().pfBackupFile
    ) {
        self.pfConfPath = pfConfPath
        self.anchorPath = anchorPath
        self.backupPath = backupPath
    }

    public func anchorRules() -> String {
        """
        table <\(Self.tableName)> persist
        block drop out quick proto { tcp udp } to <\(Self.tableName)> port { 80 443 }

        """
    }

    public func pfConfWithAnchor(existing: String) -> String {
        let cleaned = removeManagedSection(from: existing)
        let section = """
        \(Self.markerStart)
        anchor "\(Self.anchorName)"
        load anchor "\(Self.anchorName)" from "\(anchorPath.path)"
        \(Self.markerEnd)
        """
        return cleaned.trimmingCharacters(in: .newlines) + "\n\n" + section + "\n"
    }

    public func removeManagedSection(from input: String) -> String {
        var output: [String] = []
        var skipping = false
        for line in input.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces) == Self.markerStart {
                skipping = true
                continue
            }
            if line.trimmingCharacters(in: .whitespaces) == Self.markerEnd {
                skipping = false
                continue
            }
            if !skipping { output.append(line) }
        }
        while output.last == "" { output.removeLast() }
        return output.joined(separator: "\n") + "\n"
    }

    public func enable(domains: [String], dryRun: Bool = false) {
        if dryRun {
            print("[dry-run] would configure pf anchor and table for \(domains.joined(separator: ", "))")
            return
        }

        do {
            let existing = (try? String(contentsOf: pfConfPath, encoding: .utf8)) ?? ""
            try FileManager.default.createDirectory(at: backupPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: backupPath.path) {
                try existing.write(to: backupPath, atomically: true, encoding: .utf8)
            }
            try anchorRules().write(to: anchorPath, atomically: true, encoding: .utf8)
            try pfConfWithAnchor(existing: existing).write(to: pfConfPath, atomically: true, encoding: .utf8)

            guard Shell.run("/sbin/pfctl", ["-n", "-f", pfConfPath.path]) == 0 else {
                try? existing.write(to: pfConfPath, atomically: true, encoding: .utf8)
                print("[anvil] pf dry parse failed; continuing without pf")
                return
            }

            _ = Shell.run("/sbin/pfctl", ["-f", pfConfPath.path])
            // Remember whether pf was already running, so ending a session never
            // switches off a firewall the user was using before Anvil existed.
            if !isEnabled() {
                FileManager.default.createFile(atPath: AnvilPaths().pfWasOffMarker.path, contents: Data())
            }
            _ = Shell.run("/sbin/pfctl", ["-e"])
            replaceTable(domains: domains)
        } catch {
            print("[anvil] pf setup failed: \(error)")
        }
    }

    public func replaceTable(domains: [String]) {
        let ips = resolve(domains: domains)
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("anvil-pf-ips.txt")
        try? ips.joined(separator: "\n").write(to: temporary, atomically: true, encoding: .utf8)
        _ = Shell.run("/sbin/pfctl", ["-a", Self.anchorName, "-t", Self.tableName, "-T", "replace", "-f", temporary.path])
        try? FileManager.default.removeItem(at: temporary)
    }

    public func isEnabled() -> Bool {
        (Shell.output("/sbin/pfctl", ["-s", "info"]) ?? "").contains("Status: Enabled")
    }

    /// Full teardown.
    ///
    /// Flushing the table alone leaves the anchor wired into /etc/pf.conf and pf
    /// still running, so every finished session left the machine with a firewall
    /// it did not have beforehand and an anvil anchor that outlived the block.
    public func disable(dryRun: Bool = false) {
        if dryRun {
            print("[dry-run] would unload the pf anchor and restore /etc/pf.conf")
            return
        }
        _ = Shell.run("/sbin/pfctl", ["-a", Self.anchorName, "-t", Self.tableName, "-T", "flush"])
        _ = Shell.run("/sbin/pfctl", ["-a", Self.anchorName, "-F", "rules"])

        if let backup = try? String(contentsOf: backupPath, encoding: .utf8) {
            try? backup.write(to: pfConfPath, atomically: true, encoding: .utf8)
        } else {
            let current = (try? String(contentsOf: pfConfPath, encoding: .utf8)) ?? ""
            try? removeManagedSection(from: current).write(to: pfConfPath, atomically: true, encoding: .utf8)
        }
        _ = Shell.run("/sbin/pfctl", ["-f", pfConfPath.path])

        let marker = AnvilPaths().pfWasOffMarker
        if FileManager.default.fileExists(atPath: marker.path) {
            _ = Shell.run("/sbin/pfctl", ["-d"])
            try? FileManager.default.removeItem(at: marker)
        }
    }

    /// Resolves apex and www, over both A and AAAA.
    ///
    /// `dig` queries DNS directly and never consults /etc/hosts, so this still
    /// returns real addresses after the hosts block is in place. Asking only for A
    /// records leaves every IPv6-reachable host completely unblocked at the packet
    /// layer.
    public func resolve(domains: [String]) -> [String] {
        let normalized = Array(Set(domains.map { DomainNormalizer.normalize($0) }.filter { !$0.isEmpty })).sorted()
        var addresses = Set<String>()
        for domain in normalized {
            for host in [domain, "www.\(domain)"] {
                for recordType in ["A", "AAAA"] {
                    let output = Shell.output("/usr/bin/dig", ["+short", "+time=2", "+tries=1", recordType, host]) ?? ""
                    for line in output.split(separator: "\n") {
                        let value = line.split(separator: " ").last.map(String.init) ?? String(line)
                        guard value.range(of: #"^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9a-fA-F:]+$"#, options: .regularExpression) != nil else { continue }
                        // Never load a placeholder into the table: blackholing these
                        // would take out far more than the blocklist.
                        guard !["0.0.0.0", "127.0.0.1", "::", "::1"].contains(value) else { continue }
                        addresses.insert(value)
                    }
                }
            }
        }
        return addresses.sorted()
    }
}
