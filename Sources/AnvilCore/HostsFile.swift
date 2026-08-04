import Foundation

public struct HostsFile {
    public static let startMarker = "# >>> anvil"
    public static let endMarker = "# <<< anvil"

    public var path: URL

    public init(path: URL = URL(fileURLWithPath: "/etc/hosts")) {
        self.path = path
    }

    public func blockedContents(existing: String, domains: [String]) -> String {
        let base = removeManagedSection(from: existing)
        let expanded = domains.flatMap { domain -> [String] in
            let value = DomainNormalizer.normalize(domain)
            guard !value.isEmpty else { return [] }
            return value.hasPrefix("www.") ? [value] : [value, "www.\(value)"]
        }

        // Bail before folding in the DoH endpoints, not after. Adding them first
        // makes the list non-empty even when the preset blocks no sites at all, so
        // an apps-only session would still write a hosts block and break
        // DNS-over-HTTPS for no reason.
        guard !expanded.isEmpty else { return base }

        let normalized = Array(Set(expanded + HostsFile.dohEndpointDomains)).sorted()

        let lines = [Self.startMarker]
            + normalized.flatMap { ["0.0.0.0 \($0)", ":: \($0)"] }
            + [Self.endMarker]

        return base.trimmingCharacters(in: .newlines) + "\n\n" + lines.joined(separator: "\n") + "\n"
    }

    public func removeManagedSection(from input: String) -> String {
        var output: [String] = []
        var skipping = false

        for line in input.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces) == Self.startMarker {
                skipping = true
                continue
            }
            if line.trimmingCharacters(in: .whitespaces) == Self.endMarker {
                skipping = false
                continue
            }
            if !skipping {
                output.append(line)
            }
        }

        while output.last == "" { output.removeLast() }
        return output.joined(separator: "\n") + "\n"
    }

    public func apply(domains: [String], dryRun: Bool = false) throws {
        let existing = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        let next = blockedContents(existing: existing, domains: domains)
        guard next != existing else { return }
        if dryRun {
            print("[dry-run] would rewrite \(path.path)")
            return
        }
        try atomicWrite(next, to: path)
        _ = Shell.run("/usr/bin/dscacheutil", ["-flushcache"])
        _ = Shell.run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }

    public func clear(dryRun: Bool = false) throws {
        let existing = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        let next = removeManagedSection(from: existing)
        guard next != existing else { return }
        if dryRun {
            print("[dry-run] would clear Anvil hosts section")
            return
        }
        try atomicWrite(next, to: path)
    }

    private func atomicWrite(_ contents: String, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).anvil.tmp")
        try contents.write(to: temporary, atomically: true, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    /// A browser resolving over DNS-over-HTTPS never reads /etc/hosts, so the
    /// resolver endpoints are blocked too. Together with the managed policy files
    /// this collapses a browser back onto the system resolver.
    public static let dohEndpointDomains = [
        "chrome.cloudflare-dns.com",
        "cloudflare-dns.com",
        "dns.adguard.com",
        "dns.google",
        "dns.nextdns.io",
        "dns.quad9.net",
        "dns.sb",
        "dns64.dns.google",
        "doh.cleanbrowsing.org",
        "doh.dns.sb",
        "doh.opendns.com",
        "family.cloudflare-dns.com",
        "mozilla.cloudflare-dns.com",
        "one.one.one.one",
        "security.cloudflare-dns.com"
    ]
}

public enum Shell {
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return 127
        }
    }

    public static func output(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = errorPipe
        do {
            try process.run()
            // Drain the pipes before waiting.
            //
            // waitUntilExit() first deadlocks the moment a child fills the 64 KB
            // pipe buffer: it blocks writing, we block waiting, and neither side
            // moves again. `ps -axww -o pid=,command=` clears 64 KB comfortably on
            // a busy Mac, and the enforcement loop runs it every second — so the
            // daemon would hang and silently stop enforcing, with the session still
            // marked active and no way to tell from the outside.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            _ = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
