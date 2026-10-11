import Foundation

/// Where sunrise/sunset rules are computed for.
struct SolarLocation: Codable, Equatable {
    var name: String
    var latitude: Double
    var longitude: Double

    /// The representative city macOS lists for a time zone in zone.tab. A whole time zone
    /// shares one point (all of Japan uses Tokyo), which can be off by up to an hour at the
    /// edges; users fix that by setting a city by hand.
    static func fromTimeZone(
        _ timeZone: TimeZone,
        zoneTabURL: URL = URL(fileURLWithPath: "/usr/share/zoneinfo/zone.tab")
    ) -> SolarLocation? {
        guard let table = try? String(contentsOf: zoneTabURL, encoding: .utf8) else {
            AppLog.schedule.error("zone.tab unreadable path=\(zoneTabURL.path, privacy: .public)")
            return nil
        }
        for line in table.split(separator: "\n") where !line.hasPrefix("#") {
            let columns = line.split(separator: "\t")
            guard columns.count >= 3, columns[2] == timeZone.identifier,
                  let (latitude, longitude) = parseISO6709(String(columns[1]))
            else {
                continue
            }
            let city = timeZone.identifier.split(separator: "/").last.map(String.init) ?? timeZone.identifier
            return SolarLocation(
                name: city.replacingOccurrences(of: "_", with: " "),
                latitude: latitude,
                longitude: longitude
            )
        }
        return nil
    }

    /// zone.tab coordinates: ±DDMM±DDDMM or ±DDMMSS±DDDMMSS.
    static func parseISO6709(_ text: String) -> (Double, Double)? {
        guard let split = text.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else {
            return nil
        }
        guard let latitude = parseDegrees(String(text[..<split]), degreeDigits: 2),
              let longitude = parseDegrees(String(text[split...]), degreeDigits: 3)
        else {
            return nil
        }
        return (latitude, longitude)
    }

    private static func parseDegrees(_ text: String, degreeDigits: Int) -> Double? {
        guard let sign = text.first, sign == "+" || sign == "-" else {
            return nil
        }
        let digits = Array(text.dropFirst())
        guard digits.count == degreeDigits + 2 || digits.count == degreeDigits + 4,
              digits.allSatisfy(\.isNumber)
        else {
            return nil
        }
        func number(_ range: Range<Int>) -> Double {
            Double(String(digits[range]))!
        }
        var value = number(0 ..< degreeDigits) + number(degreeDigits ..< degreeDigits + 2) / 60
        if digits.count == degreeDigits + 4 {
            value += number(degreeDigits + 2 ..< degreeDigits + 4) / 3600
        }
        return sign == "-" ? -value : value
    }
}
