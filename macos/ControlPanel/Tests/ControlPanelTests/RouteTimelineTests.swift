import Foundation
import Testing
@testable import ControlPanel

struct RouteTimelineTests {
  var calendar: Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    return cal
  }
  func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
  func interval(_ start: String, _ end: String) -> RouteInterval {
    RouteInterval(route: "low_approach", startAt: Int(date(start).timeIntervalSince1970),
                  endAt: Int(date(end).timeIntervalSince1970))
  }

  @Test func sevenCalendarDaysAcrossDST() {
    let days = RouteTimeline.days(now: date("2026-03-10T12:00:00-04:00"), calendar: calendar)
    #expect(days.count == 7)
    #expect(calendar.component(.day, from: days[0]) == 4)
    #expect(days.allSatisfy { calendar.component(.hour, from: $0) == 0 })
  }

  @Test func splitsAtMidnight() {
    let span = interval("2026-09-17T23:00:00-04:00", "2026-09-18T01:00:00-04:00")
    let day = date("2026-09-18T00:00:00-04:00")
    let blocks = RouteTimeline.blocks([span], day: day, calendar: calendar)
    #expect(blocks.count == 1)
    #expect(blocks[0].top == 0)
    #expect(abs(blocks[0].height - 1.0 / 24) < 0.0001)
  }

  @Test func springMissingHourStaysBlank() {
    let span = interval("2026-03-08T01:00:00-05:00", "2026-03-08T04:00:00-04:00")
    let blocks = RouteTimeline.blocks([span], day: date("2026-03-08T00:00:00-05:00"), calendar: calendar)
    #expect(blocks.count == 2)
    #expect(abs(blocks[0].top - 1.0 / 24) < 0.0001)
    #expect(abs(blocks[1].top - 3.0 / 24) < 0.0001)
    #expect(abs(blocks.reduce(0) { $0 + $1.height } - 2.0 / 24) < 0.0001)
  }

  @Test func autumnRepeatedHourUsesLocalClock() {
    let span = interval("2026-11-01T00:00:00-04:00", "2026-11-01T03:00:00-05:00")
    let blocks = RouteTimeline.blocks([span], day: date("2026-11-01T00:00:00-04:00"), calendar: calendar)
    #expect(blocks.count == 2)
    #expect(abs(blocks[1].top - 1.0 / 24) < 0.0001)
    #expect(abs(blocks.reduce(0) { $0 + $1.height } - 4.0 / 24) < 0.0001)
  }
}
