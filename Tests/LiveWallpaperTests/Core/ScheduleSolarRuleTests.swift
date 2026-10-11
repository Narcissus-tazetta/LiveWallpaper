import XCTest

@testable import LiveWallpaper

/// Rules whose time range starts or ends at sunrise/sunset. Tokyo on 2026-06-21:
/// sunrise 4:25, sunset 19:00 JST (see SolarDayTests).
@MainActor
final class ScheduleSolarRuleTests: XCTestCase {
    private let tokyo = SolarLocation(name: "Tokyo", latitude: 35.6581, longitude: 139.7414)
    private let tromso = SolarLocation(name: "Tromsø", latitude: 69.65, longitude: 18.96)

    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private func solar(_ start: ScheduleSolarEvent?, _ end: ScheduleSolarEvent?) -> ScheduleTimeRange {
        ScheduleTimeRange(
            start: ScheduleTimeOfDay(hour: 12, minute: 0, solarEvent: start),
            end: ScheduleTimeOfDay(hour: 12, minute: 0, solarEvent: end)
        )
    }

    private func rule(_ range: ScheduleTimeRange) -> ScheduleRule {
        ScheduleRule(id: UUID(), name: "r", timeRange: range, target: .video("/tmp/a.mov"))
    }

    private func matches(
        _ range: ScheduleTimeRange, at hour: Int, _ minute: Int,
        month: Int = 6, location: SolarLocation?, timeZone: String = "Asia/Tokyo"
    ) -> Bool {
        let calendar = calendar(timeZone)
        let now = calendar.date(from: DateComponents(year: 2026, month: month, day: 21, hour: hour, minute: minute))!
        return WallpaperModel.matchingScheduleRule(
            in: [rule(range)], scope: .shared, now: now, appearance: .light,
            calendar: calendar, location: location
        ) != nil
    }

    func testDaytimeRuleFollowsTheSun() {
        let day = solar(.sunrise, .sunset)
        XCTAssertFalse(matches(day, at: 4, 20, location: tokyo))
        XCTAssertTrue(matches(day, at: 4, 30, location: tokyo))
        XCTAssertTrue(matches(day, at: 18, 55, location: tokyo))
        XCTAssertFalse(matches(day, at: 19, 5, location: tokyo))
    }

    func testNightRuleCrossesMidnight() {
        let night = solar(.sunset, .sunrise)
        XCTAssertTrue(matches(night, at: 19, 5, location: tokyo))
        XCTAssertTrue(matches(night, at: 0, 0, location: tokyo))
        XCTAssertTrue(matches(night, at: 4, 20, location: tokyo))
        XCTAssertFalse(matches(night, at: 12, 0, location: tokyo))
    }

    func testSunCanBeMixedWithAFixedTime() {
        var range = solar(.sunset, nil)
        range.end = ScheduleTimeOfDay(hour: 23, minute: 0)
        XCTAssertFalse(matches(range, at: 18, 55, location: tokyo))
        XCTAssertTrue(matches(range, at: 22, 59, location: tokyo))
        XCTAssertFalse(matches(range, at: 23, 0, location: tokyo))
    }

    func testSolarRuleNeverMatchesWithoutALocation() {
        XCTAssertFalse(matches(solar(.sunrise, .sunset), at: 12, 0, location: nil))
        XCTAssertFalse(matches(solar(.sunset, .sunrise), at: 0, 0, location: nil))
    }

    func testPolarDayAndNight() {
        let day = solar(.sunrise, .sunset)
        let night = solar(.sunset, .sunrise)
        // Midnight sun in June: daytime all day, night never.
        XCTAssertTrue(matches(day, at: 0, 30, month: 6, location: tromso, timeZone: "Europe/Oslo"))
        XCTAssertFalse(matches(night, at: 0, 30, month: 6, location: tromso, timeZone: "Europe/Oslo"))
        // Polar night in December: the opposite.
        XCTAssertFalse(matches(day, at: 12, 0, month: 12, location: tromso, timeZone: "Europe/Oslo"))
        XCTAssertTrue(matches(night, at: 12, 0, month: 12, location: tromso, timeZone: "Europe/Oslo"))
    }

    // MARK: - Stored format

    func testRulesSavedBeforeSunSupportStillDecode() throws {
        let json = Data(#"{"start":{"hour":22,"minute":0},"end":{"hour":6,"minute":0}}"#.utf8)
        let range = try JSONDecoder().decode(ScheduleTimeRange.self, from: json)
        XCTAssertNil(range.start.solarEvent)
        XCTAssertFalse(range.followsSun)
    }

    /// A version without sun support decodes only hour/minute and must not fail.
    func testSunRulesDecodeAsFixedTimesInOlderVersions() throws {
        struct OldTimeOfDay: Decodable { var hour: Int; var minute: Int }
        struct OldRange: Decodable { var start: OldTimeOfDay; var end: OldTimeOfDay }
        let range = ScheduleTimeRange(
            start: ScheduleTimeOfDay(hour: 19, minute: 0, solarEvent: .sunset),
            end: ScheduleTimeOfDay(hour: 4, minute: 25, solarEvent: .sunrise)
        )
        let old = try JSONDecoder().decode(OldRange.self, from: JSONEncoder().encode(range))
        XCTAssertEqual(old.start.hour, 19)
        XCTAssertEqual(old.end.minute, 25)
    }

    // MARK: - Time zone location

    func testTimeZoneMapsToItsZoneTabCity() throws {
        let location = try XCTUnwrap(SolarLocation.fromTimeZone(TimeZone(identifier: "Asia/Tokyo")!))
        XCTAssertEqual(location.name, "Tokyo")
        XCTAssertEqual(location.latitude, 35.65, accuracy: 0.05)
        XCTAssertEqual(location.longitude, 139.74, accuracy: 0.05)
    }

    func testISO6709Parsing() throws {
        let (lat, lon) = try XCTUnwrap(SolarLocation.parseISO6709("+404251-0740023"))
        XCTAssertEqual(lat, 40 + 42 / 60.0 + 51 / 3600.0, accuracy: 1e-9)
        XCTAssertEqual(lon, -(74 + 0 / 60.0 + 23 / 3600.0), accuracy: 1e-9)
        let (lat2, lon2) = try XCTUnwrap(SolarLocation.parseISO6709("-3352+15113"))
        XCTAssertEqual(lat2, -(33 + 52 / 60.0), accuracy: 1e-9)
        XCTAssertEqual(lon2, 151 + 13 / 60.0, accuracy: 1e-9)
    }
}
