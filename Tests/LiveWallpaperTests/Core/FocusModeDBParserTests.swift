import XCTest

@testable import LiveWallpaper

/// DoNotDisturb DBのJSONパース(FocusModeDBParser)のテスト。fixtureは実機の
/// スキーマ(Monterey以降)を必要最小限に再現したもの。
final class FocusModeDBParserTests: XCTestCase {
    private func configurationsJSON(
        workTrigger: String = ""
    ) -> Data {
        """
        {
          "data": [
            {
              "modeConfigurations": {
                "com.apple.donotdisturb.mode.default": {
                  "mode": {
                    "modeIdentifier": "com.apple.donotdisturb.mode.default",
                    "name": "",
                    "symbolImageName": "moon.fill"
                  }
                },
                "com.apple.focus.work": {
                  "mode": {
                    "modeIdentifier": "com.apple.focus.work",
                    "name": "仕事",
                    "symbolImageName": "briefcase.fill"
                  }\(workTrigger)
                },
                "com.apple.focus.personal-time": {
                  "mode": {
                    "modeIdentifier": "com.apple.focus.personal-time",
                    "name": "パーソナル",
                    "symbolImageName": "person.crop.circle"
                  }
                }
              }
            }
          ]
        }
        """.data(using: .utf8)!
    }

    /// 9:30〜18:00 の時刻トリガー(有効)を仕事モードへ付けるfixture断片。
    private var enabledWorkTrigger: String {
        """
        ,
        "triggers": {
          "triggers": [
            {
              "enabledSetting": 2,
              "timePeriodStartTimeHour": 9,
              "timePeriodStartTimeMinute": 30,
              "timePeriodEndTimeHour": 18,
              "timePeriodEndTimeMinute": 0
            }
          ]
        }
        """
    }

    private func assertionsJSON(modeIdentifier: String?) -> Data {
        guard let modeIdentifier else {
            return #"{"data": [{"storeAssertionRecords": []}]}"#.data(using: .utf8)!
        }
        return """
        {
          "data": [
            {
              "storeAssertionRecords": [
                {
                  "assertionDetails": {
                    "assertionDetailsModeIdentifier": "\(modeIdentifier)"
                  }
                }
              ]
            }
          ]
        }
        """.data(using: .utf8)!
    }

    private func date(hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 13
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)!
    }

    func testParseModesSortsDoNotDisturbFirst() {
        let modes = FocusModeDBParser.parseModes(configurationsJSON: configurationsJSON())
        XCTAssertEqual(modes.map(\.id), [
            "com.apple.donotdisturb.mode.default",
            "com.apple.focus.personal-time",
            "com.apple.focus.work",
        ])
        XCTAssertEqual(modes[2].name, "仕事")
        XCTAssertEqual(modes[2].symbolName, "briefcase.fill")
    }

    func testManualAssertionWins() {
        let active = FocusModeDBParser.parseActiveModeID(
            assertionsJSON: assertionsJSON(modeIdentifier: "com.apple.focus.work"),
            configurationsJSON: configurationsJSON(),
            now: date(hour: 12, minute: 0)
        )
        XCTAssertEqual(active, "com.apple.focus.work")
    }

    func testNoAssertionAndNoTriggerMeansInactive() {
        let active = FocusModeDBParser.parseActiveModeID(
            assertionsJSON: assertionsJSON(modeIdentifier: nil),
            configurationsJSON: configurationsJSON(),
            now: date(hour: 12, minute: 0)
        )
        XCTAssertNil(active)
    }

    /// Assertions.json はどのモードも手動オンでないとき存在しないことがある。
    func testMissingAssertionsFileFallsBackToSchedule() {
        let config = configurationsJSON(workTrigger: enabledWorkTrigger)
        XCTAssertEqual(
            FocusModeDBParser.parseActiveModeID(
                assertionsJSON: nil, configurationsJSON: config, now: date(hour: 10, minute: 0)
            ),
            "com.apple.focus.work"
        )
        XCTAssertNil(
            FocusModeDBParser.parseActiveModeID(
                assertionsJSON: nil, configurationsJSON: config, now: date(hour: 8, minute: 0)
            )
        )
        // 終了時刻ちょうどは区間外(排他的上端)。
        XCTAssertNil(
            FocusModeDBParser.parseActiveModeID(
                assertionsJSON: nil, configurationsJSON: config, now: date(hour: 18, minute: 0)
            )
        )
    }

    /// 深夜跨ぎ(22:00〜7:00)のスケジュールが日を跨いで有効になること。
    func testOvernightScheduleWrapsAroundMidnight() {
        let overnight = """
        ,
        "triggers": {
          "triggers": [
            {
              "enabledSetting": 2,
              "timePeriodStartTimeHour": 22,
              "timePeriodStartTimeMinute": 0,
              "timePeriodEndTimeHour": 7,
              "timePeriodEndTimeMinute": 0
            }
          ]
        }
        """
        let config = configurationsJSON(workTrigger: overnight)
        XCTAssertEqual(
            FocusModeDBParser.parseActiveModeID(
                assertionsJSON: nil, configurationsJSON: config, now: date(hour: 23, minute: 30)
            ),
            "com.apple.focus.work"
        )
        XCTAssertEqual(
            FocusModeDBParser.parseActiveModeID(
                assertionsJSON: nil, configurationsJSON: config, now: date(hour: 6, minute: 59)
            ),
            "com.apple.focus.work"
        )
        XCTAssertNil(
            FocusModeDBParser.parseActiveModeID(
                assertionsJSON: nil, configurationsJSON: config, now: date(hour: 12, minute: 0)
            )
        )
    }

    /// 無効化(enabledSetting != 2)されたスケジュールは判定に使わないこと。
    func testDisabledTriggerIsIgnored() {
        let disabled = enabledWorkTrigger.replacingOccurrences(
            of: "\"enabledSetting\": 2", with: "\"enabledSetting\": 1"
        )
        let config = configurationsJSON(workTrigger: disabled)
        XCTAssertNil(
            FocusModeDBParser.parseActiveModeID(
                assertionsJSON: nil, configurationsJSON: config, now: date(hour: 10, minute: 0)
            )
        )
    }

    /// 複数モードの時刻トリガーが同時にアクティブでも、判定結果が走査順に
    /// 左右されず決定的(キー昇順で最初のモード)であること。
    func testOverlappingTriggersResolveDeterministically() {
        let trigger: (Int, Int) -> String = { start, end in
            """
            "triggers": {
              "triggers": [
                {
                  "enabledSetting": 2,
                  "timePeriodStartTimeHour": \(start),
                  "timePeriodStartTimeMinute": 0,
                  "timePeriodEndTimeHour": \(end),
                  "timePeriodEndTimeMinute": 0
                }
              ]
            }
            """
        }
        let config = """
        {
          "data": [
            {
              "modeConfigurations": {
                "com.apple.focus.work": {
                  "mode": { "modeIdentifier": "com.apple.focus.work", "name": "仕事" },
                  \(trigger(9, 18))
                },
                "com.apple.focus.personal-time": {
                  "mode": { "modeIdentifier": "com.apple.focus.personal-time", "name": "パーソナル" },
                  \(trigger(17, 22))
                }
              }
            }
          ]
        }
        """.data(using: .utf8)!
        for _ in 0 ..< 10 {
            XCTAssertEqual(
                FocusModeDBParser.parseActiveModeID(
                    assertionsJSON: nil, configurationsJSON: config,
                    now: date(hour: 17, minute: 30)
                ),
                "com.apple.focus.personal-time"
            )
        }
    }

    /// スキーマが想定外でもクラッシュせず空を返すこと(非公開DBの将来変化への保険)。
    func testMalformedJSONReturnsEmpty() {
        let garbage = #"{"data": "unexpected"}"#.data(using: .utf8)!
        XCTAssertTrue(FocusModeDBParser.parseModes(configurationsJSON: garbage).isEmpty)
        XCTAssertNil(FocusModeDBParser.parseActiveModeID(
            assertionsJSON: garbage, configurationsJSON: garbage
        ))
    }
}
