import Foundation

public struct BrowserPolicy {
    public var chromePolicyPaths: [URL]
    public var firefoxPolicyPaths: [URL]
    public var backupDirectory: URL

    public init(
        chromePolicyPaths: [URL] = [
            URL(fileURLWithPath: "/Library/Managed Preferences/com.google.Chrome.plist"),
            URL(fileURLWithPath: "/Library/Managed Preferences/com.brave.Browser.plist"),
            URL(fileURLWithPath: "/Library/Managed Preferences/com.microsoft.Edge.plist"),
            URL(fileURLWithPath: "/Library/Managed Preferences/com.vivaldi.Vivaldi.plist")
        ],
        firefoxPolicyPaths: [URL] = [
            URL(fileURLWithPath: "/Applications/Firefox.app/Contents/Resources/distribution/policies.json")
        ],
        backupDirectory: URL = AnvilPaths().policyBackupDirectory
    ) {
        self.chromePolicyPaths = chromePolicyPaths
        self.firefoxPolicyPaths = firefoxPolicyPaths
        self.backupDirectory = backupDirectory
    }

    public func apply(dryRun: Bool = false) {
        if dryRun {
            print("[dry-run] would write DoH/QUIC browser policies")
            return
        }

        for path in chromePolicyPaths {
            do {
                backUp(path)
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Merge rather than overwrite: these files belong to whoever manages
                // the machine, and a policy we did not set is not ours to drop.
                var merged: [String: Any] = [:]
                if let existing = NSDictionary(contentsOf: path) as? [String: Any] {
                    merged = existing
                }
                for (key, value) in Self.managedChromeKeys { merged[key] = value }
                (merged as NSDictionary).write(to: path, atomically: true)
            } catch {
                print("[anvil] could not write \(path.path): \(error)")
            }
        }

        let firefoxPolicy: [String: Any] = [
            "policies": [
                "DNSOverHTTPS": [
                    "Enabled": false,
                    "Locked": true
                ]
            ]
        ]

        for path in firefoxPolicyPaths {
            // Only meaningful if the browser is installed. Derived from the policy
            // path rather than hardcoded, so an injected path still works:
            // .../Firefox.app/Contents/Resources/distribution/policies.json
            let bundleRoot = path
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: bundleRoot.path) else { continue }
            do {
                backUp(path)
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONSerialization.data(withJSONObject: firefoxPolicy, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: path, options: .atomic)
            } catch {
                print("[anvil] could not write \(path.path): \(error)")
            }
        }
    }

    /// Restores what was there before, rather than deleting.
    ///
    /// Deleting unconditionally destroys managed preferences Anvil never wrote —
    /// an MDM profile's Chrome policy, or a legitimate Firefox distribution file —
    /// and there is no way to put those back afterwards.
    public func clear(dryRun: Bool = false) {
        if dryRun {
            print("[dry-run] would restore browser policies to their previous state")
            return
        }
        for path in chromePolicyPaths + firefoxPolicyPaths {
            restore(path)
        }
    }

    public static let managedChromeKeys: [String: Any] = [
        "DnsOverHttpsMode": "off",
        "QuicAllowed": false
    ]

    // MARK: - Backup bookkeeping

    private func backupSlot(for url: URL) -> URL {
        backupDirectory.appendingPathComponent(url.path.replacingOccurrences(of: "/", with: "_"))
    }

    /// A ".absent" marker records "there was nothing here before", so a restore
    /// removes the file instead of leaving a policy the user never had.
    private func backUp(_ url: URL) {
        let slot = backupSlot(for: url)
        let absent = slot.appendingPathExtension("absent")
        let fm = FileManager.default
        guard !fm.fileExists(atPath: slot.path), !fm.fileExists(atPath: absent.path) else { return }
        try? fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            try? fm.copyItem(at: url, to: slot)
        } else {
            fm.createFile(atPath: absent.path, contents: Data())
        }
    }

    private func restore(_ url: URL) {
        let slot = backupSlot(for: url)
        let absent = slot.appendingPathExtension("absent")
        let fm = FileManager.default
        if fm.fileExists(atPath: slot.path) {
            try? fm.removeItem(at: url)
            try? fm.copyItem(at: slot, to: url)
            try? fm.removeItem(at: slot)
        } else if fm.fileExists(atPath: absent.path) {
            try? fm.removeItem(at: url)
            try? fm.removeItem(at: absent)
        }
        // No backup recorded means we never wrote this file. Leave it alone.
    }

    public func purgeRunningBrowsers(dryRun: Bool = false) {
        let browserPreset = Preset(
            name: "Browsers",
            appBundleIDs: [
                "com.apple.Safari",
                "com.google.Chrome",
                "com.brave.Browser",
                "com.microsoft.Edge",
                "org.mozilla.firefox"
            ],
            appPaths: [
                "/Applications/Safari.app",
                "/Applications/Google Chrome.app",
                "/Applications/Brave Browser.app",
                "/Applications/Microsoft Edge.app",
                "/Applications/Firefox.app"
            ],
            domains: [],
            defaultMinutes: 15
        )
        ProcessScanner().enforce(preset: browserPreset, dryRun: dryRun, includeEscapeTools: false)
    }
}
