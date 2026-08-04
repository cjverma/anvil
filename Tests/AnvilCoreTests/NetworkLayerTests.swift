import XCTest
@testable import AnvilCore

final class DomainNormalizerTests: XCTestCase {
    func testSchemePathPortAndWWWAreStripped() {
        XCTAssertEqual(DomainNormalizer.normalize("https://www.Reddit.com/r/all"), "reddit.com")
        XCTAssertEqual(DomainNormalizer.normalize("http://news.ycombinator.com"), "news.ycombinator.com")
        XCTAssertEqual(DomainNormalizer.normalize("example.com:8080"), "example.com")
        XCTAssertEqual(DomainNormalizer.normalize("  EXAMPLE.com.  "), "example.com")
    }

    func testWWWFoldsIntoTheApexSoEntriesDedupe() {
        // Left separate these never collapse through Set, and the hosts block ends
        // up carrying a nonsense "www.www.reddit.com".
        XCTAssertEqual(
            DomainNormalizer.normalize("www.reddit.com"),
            DomainNormalizer.normalize("reddit.com")
        )
    }

    func testAHostCalledWWWIsNotEatenEntirely() {
        XCTAssertEqual(DomainNormalizer.normalize("www."), "www")
    }
}

final class HostsFileEdgeCaseTests: XCTestCase {
    let hosts = HostsFile(path: URL(fileURLWithPath: "/tmp/anvil-test-hosts"))
    let userContent = """
    ##
    # Host Database
    ##
    127.0.0.1	localhost
    255.255.255.255	broadcasthost
    10.0.0.5        my-nas.local
    """

    func testUserContentSurvivesAndIsRestoredExactly() {
        let blocked = hosts.blockedContents(existing: userContent, domains: ["reddit.com"])
        XCTAssertTrue(blocked.contains("127.0.0.1\tlocalhost"))
        XCTAssertTrue(blocked.contains("10.0.0.5        my-nas.local"))
        XCTAssertEqual(hosts.removeManagedSection(from: blocked), userContent + "\n")
    }

    func testRewriteIsStableAcrossInputOrdering() {
        let a = hosts.blockedContents(existing: userContent, domains: ["x.com", "reddit.com"])
        let b = hosts.blockedContents(existing: userContent, domains: ["reddit.com", "x.com"])
        XCTAssertEqual(a, b, "reordering a blocklist must not read as drift and trigger a rewrite")
    }

    func testEquivalentSpellingsProduceOneEntry() {
        let blocked = hosts.blockedContents(
            existing: userContent,
            domains: ["reddit.com", "www.reddit.com", "https://reddit.com/r/x"]
        )
        let apexLines = blocked.components(separatedBy: "\n").filter { $0 == "0.0.0.0 reddit.com" }
        XCTAssertEqual(apexLines.count, 1)
        XCTAssertFalse(blocked.contains("www.www."))
    }

    func testAnUnterminatedSectionIsStrippedToEndOfFile() {
        let broken = userContent + "\n" + HostsFile.startMarker + "\n0.0.0.0 reddit.com\n"
        XCTAssertEqual(hosts.removeManagedSection(from: broken), userContent + "\n")
    }

    func testAppsOnlyPresetWritesNoHostsBlock() {
        // The DoH endpoints must not be enough on their own to make the list
        // non-empty, or a session that blocks no sites still breaks DoH.
        let result = hosts.blockedContents(existing: userContent, domains: [])
        XCTAssertFalse(result.contains(HostsFile.startMarker))
        XCTAssertFalse(result.contains("dns.google"))
    }

    func testDoHEndpointsAreBlockedAlongsideRealDomains() {
        let result = hosts.blockedContents(existing: userContent, domains: ["reddit.com"])
        XCTAssertTrue(result.contains("0.0.0.0 dns.google"))
        XCTAssertTrue(result.contains("0.0.0.0 mozilla.cloudflare-dns.com"))
    }
}

final class PFAnchorTests: XCTestCase {
    let pf = PFAnchor()
    let applePFConf = """
    scrub-anchor "com.apple/*"
    nat-anchor "com.apple/*"
    rdr-anchor "com.apple/*"
    dummynet-anchor "com.apple/*"
    anchor "com.apple/*"
    load anchor "com.apple" from "/etc/pf.anchors/com.apple"
    """

    func testAnchorIsAppendedAfterTheExistingRuleset() {
        let result = pf.pfConfWithAnchor(existing: applePFConf)
        let ours = result.range(of: "anchor \"anvil\"")
        let apple = result.range(of: "load anchor \"com.apple\"")
        XCTAssertNotNil(ours)
        XCTAssertNotNil(apple)
        // Filter anchors have to come last in a pf ruleset or the load is refused.
        XCTAssertTrue(apple!.lowerBound < ours!.lowerBound)
    }

    func testAnchorInsertionIsIdempotent() {
        let once = pf.pfConfWithAnchor(existing: applePFConf)
        let twice = pf.pfConfWithAnchor(existing: once)
        XCTAssertEqual(once, twice)
        XCTAssertEqual(pf.removeManagedSection(from: twice), applePFConf + "\n")
    }

    func testBothTransportsAreBlocked() {
        // QUIC rides UDP 443. Blocking only TCP leaves a browser a clean way around
        // the hosts file for any address it has already learned.
        let rules = pf.anchorRules()
        XCTAssertTrue(rules.contains("tcp"))
        XCTAssertTrue(rules.contains("udp"))
        XCTAssertTrue(rules.contains("443"))
        XCTAssertTrue(rules.contains("table <anvil_blocked> persist"))
    }
}

final class BrowserPolicyTests: XCTestCase {
    func testPolicyClosesBothBypassRoutes() {
        XCTAssertEqual(BrowserPolicy.managedChromeKeys["DnsOverHttpsMode"] as? String, "off")
        XCTAssertEqual(BrowserPolicy.managedChromeKeys["QuicAllowed"] as? Bool, false)
    }

    func testPolicyIsSerialisableAsAPlist() throws {
        // Catches a non-plist value being added, which would otherwise fail only at
        // runtime as root and leave the browser layer silently unapplied.
        let data = try PropertyListSerialization.data(
            fromPropertyList: BrowserPolicy.managedChromeKeys, format: .xml, options: 0
        )
        XCTAssertFalse(data.isEmpty)
    }

    func testChromiumPoliciesTargetManagedPreferences() {
        for path in BrowserPolicy().chromePolicyPaths {
            XCTAssertTrue(path.path.hasPrefix("/Library/Managed Preferences/"))
            XCTAssertTrue(path.pathExtension == "plist")
        }
    }

    func testBackupRoundTripRestoresAndRemovesCorrectly() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let existing = sandbox.appendingPathComponent("existing.plist")
        let absent = sandbox.appendingPathComponent("absent.plist")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        try "original".write(to: existing, atomically: true, encoding: .utf8)

        let policy = BrowserPolicy(
            chromePolicyPaths: [existing, absent],
            firefoxPolicyPaths: [],
            backupDirectory: sandbox.appendingPathComponent("backups")
        )
        policy.apply()

        XCTAssertNotEqual(try String(contentsOf: existing, encoding: .utf8), "original")
        XCTAssertTrue(FileManager.default.fileExists(atPath: absent.path))

        policy.clear()

        // A file that existed comes back byte for byte; one we created is removed.
        // Deleting unconditionally would destroy an MDM-managed policy Anvil never
        // wrote, with no way to put it back.
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
    }
}
