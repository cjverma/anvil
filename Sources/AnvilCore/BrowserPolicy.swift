import Foundation

public struct BrowserPolicy {
    public var chromePolicyPaths: [URL]
    public var firefoxPolicyPaths: [URL]

    public init(
        chromePolicyPaths: [URL] = [
            URL(fileURLWithPath: "/Library/Managed Preferences/com.google.Chrome.plist"),
            URL(fileURLWithPath: "/Library/Managed Preferences/com.brave.Browser.plist"),
            URL(fileURLWithPath: "/Library/Managed Preferences/com.microsoft.Edge.plist")
        ],
        firefoxPolicyPaths: [URL] = [
            URL(fileURLWithPath: "/Applications/Firefox.app/Contents/Resources/distribution/policies.json")
        ]
    ) {
        self.chromePolicyPaths = chromePolicyPaths
        self.firefoxPolicyPaths = firefoxPolicyPaths
    }

    public func apply(dryRun: Bool = false) {
        if dryRun {
            print("[dry-run] would write DoH/QUIC browser policies")
            return
        }

        let chromePolicy: [String: Any] = [
            "DnsOverHttpsMode": "off",
            "QuicAllowed": false
        ]

        for path in chromePolicyPaths {
            do {
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                (chromePolicy as NSDictionary).write(to: path, atomically: true)
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
            do {
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONSerialization.data(withJSONObject: firefoxPolicy, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: path, options: .atomic)
            } catch {
                print("[anvil] could not write \(path.path): \(error)")
            }
        }
    }

    public func clear(dryRun: Bool = false) {
        if dryRun {
            print("[dry-run] would remove Anvil browser policies")
            return
        }
        for path in chromePolicyPaths + firefoxPolicyPaths {
            try? FileManager.default.removeItem(at: path)
        }
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
