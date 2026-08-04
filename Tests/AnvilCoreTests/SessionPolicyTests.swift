import XCTest
@testable import AnvilCore

final class SessionPolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func preset(_ name: String = "Test", domains: [String] = ["reddit.com"], apps: [String] = []) -> Preset {
        Preset(name: name, appBundleIDs: apps, domains: domains, defaultMinutes: 60)
    }

    // MARK: - The no-early-exit property

    func testDeadlineCannotBeShortened() {
        // Asking for one minute while sixty remain is the obvious way out, and the
        // protocol has to refuse it. This is the single most important assertion here.
        let current = Session(startedAt: now, endsAt: now.addingTimeInterval(3_600), preset: preset())
        XCTAssertThrowsError(
            try SessionPolicy.validatedSession(
                request: StartRequest(preset: preset(), minutes: 1),
                current: current,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? RequestValidationError, .doesNotExtend)
        }
    }

    func testEqualDeadlineIsAlsoRefused() {
        let current = Session(startedAt: now, endsAt: now.addingTimeInterval(3_600), preset: preset())
        XCTAssertThrowsError(
            try SessionPolicy.validatedSession(
                request: StartRequest(preset: preset(), minutes: 60),
                current: current,
                now: now
            )
        )
    }

    func testDeadlineExtendsAndStartedAtSurvives() throws {
        let started = now.addingTimeInterval(-1_800)
        let current = Session(startedAt: started, endsAt: now.addingTimeInterval(600), preset: preset())
        let updated = try SessionPolicy.validatedSession(
            request: StartRequest(preset: preset(), minutes: 60),
            current: current,
            now: now
        )
        XCTAssertEqual(updated.endsAt, now.addingTimeInterval(3_600))
        XCTAssertEqual(updated.startedAt, started, "extending must not restart the clock")
    }

    // MARK: - Blocklists only widen

    func testExtendingUnionsBlocklistsAndNeverDropsEntries() throws {
        let wide = preset(domains: ["reddit.com", "x.com"], apps: ["com.tinyspeck.slackmacgap"])
        let current = Session(startedAt: now, endsAt: now.addingTimeInterval(600), preset: wide)
        let updated = try SessionPolicy.validatedSession(
            request: StartRequest(preset: preset(domains: ["news.ycombinator.com"]), minutes: 120),
            current: current,
            now: now
        )
        XCTAssertEqual(
            Set(updated.preset.domains),
            ["reddit.com", "x.com", "news.ycombinator.com"],
            "a narrower request must not remove anything"
        )
        XCTAssertEqual(updated.preset.appBundleIDs, ["com.tinyspeck.slackmacgap"])
    }

    // MARK: - Duration cap

    func testDurationBounds() {
        for minutes in [0, -1, -600, SessionPolicy.maximumMinutes + 1] {
            XCTAssertThrowsError(
                try SessionPolicy.validatedSession(
                    request: StartRequest(preset: preset(), minutes: minutes),
                    current: nil,
                    now: now
                ),
                "\(minutes) minutes must be rejected"
            ) { error in
                XCTAssertEqual(error as? RequestValidationError, .invalidDuration)
            }
        }
    }

    func testExactlyTheCapIsAllowed() throws {
        let session = try SessionPolicy.validatedSession(
            request: StartRequest(preset: preset(), minutes: SessionPolicy.maximumMinutes),
            current: nil,
            now: now
        )
        XCTAssertEqual(session.endsAt, now.addingTimeInterval(TimeInterval(SessionPolicy.maximumMinutes * 60)))
    }

    // MARK: - Expiry

    func testExpiredSessionDoesNotLingerIntoTheNextOne() throws {
        let expired = Session(
            startedAt: now.addingTimeInterval(-7_200),
            endsAt: now.addingTimeInterval(-60),
            preset: preset(domains: ["old.com"])
        )
        let session = try SessionPolicy.validatedSession(
            request: StartRequest(preset: preset(domains: ["new.com"]), minutes: 30),
            current: expired,
            now: now
        )
        XCTAssertEqual(session.preset.domains, ["new.com"], "an expired blocklist must not carry over")
        XCTAssertEqual(session.startedAt, now)
    }

    // MARK: - Codec

    func testRequestRoundTripsAndStaysUnderTheSocketCap() throws {
        let big = Preset(
            name: String(repeating: "n", count: 60),
            appBundleIDs: (0..<20).map { "com.example.app\($0)" },
            appPaths: (0..<20).map { "/Applications/App\($0).app" },
            domains: (0..<20).map { "domain\($0).com" },
            defaultMinutes: 60
        )
        let data = try JSONFiles.encoder.encode(StartRequest(preset: big, minutes: 60))
        XCTAssertLessThan(data.count, ControlSocketServer.maxPayloadBytes)

        let decoded = try JSONFiles.decoder.decode(StartRequest.self, from: data)
        XCTAssertEqual(decoded.minutes, 60)
        XCTAssertEqual(decoded.preset.domains.count, 20)
    }

    func testMalformedPayloadIsRejected() {
        XCTAssertThrowsError(try JSONFiles.decoder.decode(StartRequest.self, from: Data("not json".utf8)))
        XCTAssertThrowsError(try JSONFiles.decoder.decode(StartRequest.self, from: Data(#"{"minutes":5}"#.utf8)))
    }
}
