import XCTest

@testable import LiveWallpaper

/// Expected times are from the National Astronomical Observatory of Japan's 2026 tables
/// (eco.mtk.nao.ac.jp/koyomi/dni/2026/), which are published to the minute.
final class SolarDayTests: XCTestCase {
    private var tokyoCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    private func assertSunTimes(
        year: Int, month: Int, day: Int,
        latitude: Double, longitude: Double,
        sunrise: (Int, Int), sunset: (Int, Int),
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let calendar = tokyoCalendar
        let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        guard case let .normal(rise, set) = SolarDay.compute(
            for: date, latitude: latitude, longitude: longitude, calendar: calendar
        ) else {
            return XCTFail("expected a normal day", file: file, line: line)
        }
        func minutes(_ date: Date) -> Double {
            let c = calendar.dateComponents([.hour, .minute, .second], from: date)
            return Double(c.hour! * 60 + c.minute!) + Double(c.second!) / 60
        }
        XCTAssertEqual(minutes(rise), Double(sunrise.0 * 60 + sunrise.1), accuracy: 1, "sunrise", file: file, line: line)
        XCTAssertEqual(minutes(set), Double(sunset.0 * 60 + sunset.1), accuracy: 1, "sunset", file: file, line: line)
    }

    func testTokyoSummerSolstice() {
        assertSunTimes(year: 2026, month: 6, day: 21, latitude: 35.6581, longitude: 139.7414,
                       sunrise: (4, 25), sunset: (19, 0))
    }

    func testTokyoWinterSolstice() {
        assertSunTimes(year: 2026, month: 12, day: 21, latitude: 35.6581, longitude: 139.7414,
                       sunrise: (6, 46), sunset: (16, 31))
    }

    func testKagoshimaSolstices() {
        assertSunTimes(year: 2026, month: 6, day: 21, latitude: 31.6, longitude: 130.55,
                       sunrise: (5, 13), sunset: (19, 26))
        assertSunTimes(year: 2026, month: 12, day: 21, latitude: 31.6, longitude: 130.55,
                       sunrise: (7, 13), sunset: (17, 18))
    }

    func testNemuroEquinox() {
        assertSunTimes(year: 2026, month: 3, day: 20, latitude: 43.3333, longitude: 145.5833,
                       sunrise: (5, 22), sunset: (17, 29))
    }

    func testPolarDayAndNightInTromso() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
        let june = calendar.date(from: DateComponents(year: 2026, month: 6, day: 21, hour: 12))!
        let december = calendar.date(from: DateComponents(year: 2026, month: 12, day: 21, hour: 12))!

        XCTAssertEqual(SolarDay.compute(for: june, latitude: 69.65, longitude: 18.96, calendar: calendar), .polarDay)
        XCTAssertEqual(SolarDay.compute(for: december, latitude: 69.65, longitude: 18.96, calendar: calendar), .polarNight)
    }
}
