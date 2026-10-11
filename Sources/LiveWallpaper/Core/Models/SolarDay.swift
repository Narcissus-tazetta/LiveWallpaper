import Foundation

/// Sunrise and sunset for one local calendar day at one place.
enum SolarDay: Equatable {
    case normal(sunrise: Date, sunset: Date)
    /// The sun stays above the horizon all day (midnight sun).
    case polarDay
    /// The sun stays below the horizon all day.
    case polarNight

    /// NOAA's solar calculator equations (the ones behind its sunrise/sunset spreadsheet).
    /// Accurate to about a minute between ±72° latitude, which is all an HH:mm schedule needs.
    static func compute(
        for date: Date,
        latitude: Double,
        longitude: Double,
        calendar: Calendar
    ) -> SolarDay {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let utcMidnight = utc.date(from: DateComponents(year: day.year, month: day.month, day: day.day))!

        // Evaluate the orbit at local solar noon of that day; the sun moves too little
        // between noon and sunrise/sunset to matter at minute resolution.
        let julianDay = utcMidnight.timeIntervalSince1970 / 86400 + 2_440_587.5 + (0.5 - longitude / 360)
        let t = (julianDay - 2_451_545) / 36525

        let meanLongitude = (280.46646 + t * (36000.76983 + t * 0.0003032))
            .truncatingRemainder(dividingBy: 360)
        let meanAnomaly = 357.52911 + t * (35999.05029 - 0.0001537 * t)
        let eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let m = radians(meanAnomaly)
        let equationOfCenter = sin(m) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(2 * m) * (0.019993 - 0.000101 * t)
            + sin(3 * m) * 0.000289
        let omega = radians(125.04 - 1934.136 * t)
        let apparentLongitude = meanLongitude + equationOfCenter - 0.00569 - 0.00478 * sin(omega)
        let meanObliquity = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let obliquity = radians(meanObliquity + 0.00256 * cos(omega))
        let declination = asin(sin(obliquity) * sin(radians(apparentLongitude)))

        let y = pow(tan(obliquity / 2), 2)
        let l0 = radians(meanLongitude)
        let equationOfTimeMinutes = 4 * degrees(
            y * sin(2 * l0)
                - 2 * eccentricity * sin(m)
                + 4 * eccentricity * y * sin(m) * cos(2 * l0)
                - 0.5 * y * y * sin(4 * l0)
                - 1.25 * eccentricity * eccentricity * sin(2 * m)
        )

        // 90.833° = refraction (34′) + the sun's apparent radius (16′), the same
        // "upper limb touches the horizon" definition almanacs use.
        let lat = radians(latitude)
        let cosHourAngle = cos(radians(90.833)) / (cos(lat) * cos(declination)) - tan(lat) * tan(declination)
        if cosHourAngle < -1 {
            return .polarDay
        }
        if cosHourAngle > 1 {
            return .polarNight
        }
        let hourAngleMinutes = 4 * degrees(acos(cosHourAngle))
        let solarNoonMinutes = 720 - 4 * longitude - equationOfTimeMinutes
        return .normal(
            sunrise: utcMidnight.addingTimeInterval((solarNoonMinutes - hourAngleMinutes) * 60),
            sunset: utcMidnight.addingTimeInterval((solarNoonMinutes + hourAngleMinutes) * 60)
        )
    }

    private static func radians(_ degrees: Double) -> Double {
        degrees * .pi / 180
    }

    private static func degrees(_ radians: Double) -> Double {
        radians * 180 / .pi
    }
}
