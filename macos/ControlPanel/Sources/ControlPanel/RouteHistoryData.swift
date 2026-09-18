import Foundation

struct RouteInterval: Codable {
  let route: String
  let startAt: Int
  let endAt: Int
}

struct RouteShare: Codable, Identifiable {
  let route: String
  let seconds: Int
  let percent: Double
  var id: String { route }
}

struct RouteHistoryResponse: Codable {
  let asOf: Int
  let windowStart: Int
  let intervals: [RouteInterval]
  let shares: [RouteShare]
  let classifiedSeconds: Int
  let windowSeconds: Int
}

enum RouteTimeline {
  struct Block {
    let route: String
    let start: Date
    let end: Date
    let top: Double
    let height: Double
  }

  /// Today and the six preceding local calendar days, oldest first.
  static func days(now: Date, calendar: Calendar = .current) -> [Date] {
    let today = calendar.startOfDay(for: now)
    return (-6...0).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
  }

  /// Split at midnight and DST transitions so the vertical scale is local wall time.
  /// The repeated autumn hour occupies the same rows; absent spring time stays blank.
  static func blocks(_ intervals: [RouteInterval], day: Date,
                     calendar: Calendar = .current) -> [Block] {
    guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) else { return [] }
    return intervals.flatMap { span -> [Block] in
      var start = max(day, Date(timeIntervalSince1970: Double(span.startAt)))
      let end = min(dayEnd, Date(timeIntervalSince1970: Double(span.endAt)))
      var result: [Block] = []
      while start < end {
        let transition = calendar.timeZone.nextDaylightSavingTimeTransition(after: start)
        let finish = transition.map { min($0, end) } ?? end
        guard finish > start else { break }
        let c = calendar.dateComponents([.hour, .minute, .second], from: start)
        let seconds = Double((c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0))
        result.append(Block(route: span.route, start: start, end: finish,
                            top: seconds / 86400, height: finish.timeIntervalSince(start) / 86400))
        start = finish
      }
      return result
    }
  }
}
