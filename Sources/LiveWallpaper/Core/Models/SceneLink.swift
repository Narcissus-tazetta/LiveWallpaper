import Foundation

/// A part of the day. Each starts at a time of the scene's choosing and lasts until
/// the next one starts.
/// Keys `SceneLink.timeValues` by name in scene.json, not as a key-value array.
enum SceneTimeOfDay: String, Codable, CaseIterable, CodingKeyRepresentable {
    case morning
    case day
    case evening
    case night
}

struct SceneTimeBand: Codable, Equatable {
    var timeOfDay: SceneTimeOfDay
    /// Minutes after midnight, 0..<1440.
    var startMinute: Int

    static let defaults = [
        SceneTimeBand(timeOfDay: .morning, startMinute: 6 * 60),
        SceneTimeBand(timeOfDay: .day, startMinute: 10 * 60),
        SceneTimeBand(timeOfDay: .evening, startMinute: 17 * 60),
        SceneTimeBand(timeOfDay: .night, startMinute: 19 * 60)
    ]
}

/// What a link changes on a layer. The identity changes nothing; several links on one
/// layer add their offsets, turns, brightness and warmth and multiply the rest.
struct SceneLinkValues: Codable, Equatable {
    static let scaleRange = 0.25 ... 4.0

    /// Fractions of the canvas, +y down.
    var offsetX: Double = 0
    var offsetY: Double = 0
    /// Degrees, clockwise.
    var rotation: Double = 0
    var scale: Double = 1
    var scaleY: Double?
    /// Multiplies the layer's opacity.
    var opacity: Double = 1
    /// -1...1: -1 is black, 1 doubles.
    var brightness: Double = 0
    /// 0 is grey, 1 unchanged, 2 twice as vivid.
    var saturation: Double = 1
    /// -1 cool ... 1 warm.
    var warmth: Double = 0

    static let identity = SceneLinkValues()

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        offsetX = (try? container.decode(Double.self, forKey: .offsetX)) ?? 0
        offsetY = (try? container.decode(Double.self, forKey: .offsetY)) ?? 0
        rotation = (try? container.decode(Double.self, forKey: .rotation)) ?? 0
        scale = (try? container.decode(Double.self, forKey: .scale)) ?? 1
        scaleY = try? container.decodeIfPresent(Double.self, forKey: .scaleY)
        opacity = (try? container.decode(Double.self, forKey: .opacity)) ?? 1
        brightness = (try? container.decode(Double.self, forKey: .brightness)) ?? 0
        saturation = (try? container.decode(Double.self, forKey: .saturation)) ?? 1
        warmth = (try? container.decode(Double.self, forKey: .warmth)) ?? 0
    }

    var changesColor: Bool {
        brightness != 0 || saturation != 1 || warmth != 0
    }

    /// From the identity (0) to these values (1).
    func scaled(by t: Double) -> SceneLinkValues {
        var result = SceneLinkValues()
        result.offsetX = offsetX * t
        result.offsetY = offsetY * t
        result.rotation = rotation * t
        // Log space, so a zoom feels even, as in keyframes.
        result.scale = exp(log(max(scale, 0.01)) * t)
        if let scaleY { result.scaleY = exp(log(max(scaleY, 0.01)) * t) }
        result.opacity = 1 + (opacity - 1) * t
        result.brightness = brightness * t
        result.saturation = 1 + (saturation - 1) * t
        result.warmth = warmth * t
        return result
    }

    func combined(with other: SceneLinkValues) -> SceneLinkValues {
        var result = self
        result.offsetX += other.offsetX
        result.offsetY += other.offsetY
        result.rotation += other.rotation
        result.scale *= other.scale
        if scaleY != nil || other.scaleY != nil {
            result.scaleY = (scaleY ?? scale) * (other.scaleY ?? other.scale)
        }
        result.opacity *= other.opacity
        result.brightness += other.brightness
        result.saturation *= other.saturation
        result.warmth += other.warmth
        return result
    }
}

enum SceneLinkInput: String, Codable, CaseIterable {
    case timeOfDay
    /// -1 at the left edge of the screen, 1 at the right.
    case cursorX
    /// -1 at the top, 1 at the bottom.
    case cursorY
    /// 0 at the centre, 1 at the edges.
    case cursorDistance

    var usesCursor: Bool {
        self != .timeOfDay
    }
}

/// Ties layers to the time of day or the cursor. With the cursor, the values change
/// nothing at the centre and reach `start`/`end` at the edges, so the lock screen and
/// the baked video (cursor at the centre) show the layers as placed.
struct SceneLink: Codable, Equatable, Identifiable {
    var id = UUID()
    var input: SceneLinkInput
    var isEnabled = true
    /// Moved together; ids of layers that no longer exist are ignored.
    var layerIDs: [UUID]
    /// Time of day: the values of each part of the day (missing ones change nothing).
    var timeValues: [SceneTimeOfDay: SceneLinkValues] = [:]
    /// Cursor: at the left or top edge (unused for the distance).
    var start = SceneLinkValues()
    /// Cursor: at the right or bottom edge, or anywhere on the edge for the distance.
    var end = SceneLinkValues()

    init(input: SceneLinkInput, layerIDs: [UUID]) {
        self.input = input
        self.layerIDs = layerIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        input = try container.decode(SceneLinkInput.self, forKey: .input)
        isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? true
        layerIDs = (try? container.decode([UUID].self, forKey: .layerIDs)) ?? []
        timeValues = (try? container.decode([SceneTimeOfDay: SceneLinkValues].self, forKey: .timeValues)) ?? [:]
        start = (try? container.decode(SceneLinkValues.self, forKey: .start)) ?? SceneLinkValues()
        end = (try? container.decode(SceneLinkValues.self, forKey: .end)) ?? SceneLinkValues()
    }

    /// `cursor` is -1...1 per axis (+y down), the same eased value the parallax uses.
    func values(timeOfDay: SceneTimeOfDay, cursor: SIMD2<Double>) -> SceneLinkValues {
        switch input {
        case .timeOfDay:
            return timeValues[timeOfDay] ?? .identity
        case .cursorX:
            return cursor.x < 0 ? start.scaled(by: min(-cursor.x, 1)) : end.scaled(by: min(cursor.x, 1))
        case .cursorY:
            return cursor.y < 0 ? start.scaled(by: min(-cursor.y, 1)) : end.scaled(by: min(cursor.y, 1))
        case .cursorDistance:
            return end.scaled(by: min((cursor.x * cursor.x + cursor.y * cursor.y).squareRoot(), 1))
        }
    }

    /// Changes something at some time of day or some cursor position.
    var hasEffect: Bool {
        guard isEnabled, !layerIDs.isEmpty else {
            return false
        }
        switch input {
        case .timeOfDay:
            return timeValues.values.contains { $0 != .identity }
        case .cursorX, .cursorY:
            return start != .identity || end != .identity
        case .cursorDistance:
            return end != .identity
        }
    }
}

extension SceneDocument {
    /// The part of the day at `date`: the one that started last, or yesterday's last.
    func timeOfDay(at date: Date, calendar: Calendar = .current) -> SceneTimeOfDay {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let sorted = timeBands.sorted { $0.startMinute < $1.startMinute }
        return (sorted.last { $0.startMinute <= minute } ?? sorted.last)?.timeOfDay ?? .day
    }

    /// The next moment a part of the day starts, after `date`.
    func nextTimeOfDayChange(after date: Date, calendar: Calendar = .current) -> Date? {
        timeBands.compactMap { band in
            calendar.nextDate(
                after: date,
                matching: DateComponents(hour: band.startMinute / 60, minute: band.startMinute % 60, second: 0),
                matchingPolicy: .nextTime
            )
        }.min()
    }

    /// The scene looks the same in both parts of the day (the links set the same
    /// values for them), so a video baked for one serves the other.
    func looksSame(at first: SceneTimeOfDay, as second: SceneTimeOfDay) -> Bool {
        if first != second, scripts.contains(where: { $0.canRun && $0.usesTimeOfDay }) { return false }
        return links.allSatisfy { link in
            link.input != .timeOfDay || !link.isEnabled || link.layerIDs.isEmpty
                || (link.timeValues[first] ?? .identity) == (link.timeValues[second] ?? .identity)
        }
    }

    var usesTimeOfDay: Bool {
        links.contains { $0.input == .timeOfDay && $0.hasEffect } || scripts.contains { $0.canRun && $0.usesTimeOfDay }
    }

    /// What the links change on the layer for these inputs; the identity when none apply.
    func linkValues(layerID: UUID, timeOfDay: SceneTimeOfDay, cursor: SIMD2<Double>) -> SceneLinkValues {
        var result = SceneLinkValues.identity
        for link in links where link.isEnabled && link.layerIDs.contains(layerID) {
            result = result.combined(with: link.values(timeOfDay: timeOfDay, cursor: cursor))
        }
        return result
    }

    /// Puts `newID` in every link `existingID` is in, for a layer split off another
    /// (a cut-out, a copy) that should keep looking the same.
    mutating func linkLayer(_ newID: UUID, likeLayer existingID: UUID) {
        for index in links.indices where links[index].layerIDs.contains(existingID) && !links[index].layerIDs.contains(newID) {
            links[index].layerIDs.append(newID)
        }
        for index in scripts.indices where scripts[index].layerIDs.contains(existingID) {
            scripts[index].layerIDs.append(newID)
        }
    }
}
