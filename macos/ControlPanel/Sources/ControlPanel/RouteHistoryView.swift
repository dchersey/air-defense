import SwiftUI

struct RouteHistoryView: View {
  let model: StatusModel
  let onBack: () -> Void
  @State private var hovered: String?
  private let gridHeight: CGFloat = 240
  private let routes = ["low_approach", "high_approach", "river_approach", "direct_approach"]

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Button(action: onBack) { Image(systemName: "chevron.left") }
            .buttonStyle(.plain).accessibilityLabel("Back")
          Text("Route history").font(.adTitle)
          Spacer()
          Text("7 days · LGA").font(.adMono).foregroundStyle(Palette.ink3)
        }
        Text("RUNWAY FLOW BY HOUR")
          .font(.adMono).foregroundStyle(Palette.ink2)
        chart(now: context.date)
        ZStack(alignment: .topLeading) {
          historyKey.opacity(hovered == nil ? 1 : 0)
          if let hovered {
            Text(hovered).font(.adMono).foregroundStyle(Palette.ink2)
          }
        }
        Divider().overlay(Palette.hairline)
        monthly
        if model.routeHistoryError || !model.reachable {
          Text("History unavailable · showing last saved view")
            .font(.adMono).foregroundStyle(Palette.inbound)
        } else if let data = model.routeHistory, data.classifiedSeconds == 0, data.intervals.isEmpty {
          Text("History starts as routes are classified. Earlier days will stay blank.")
            .font(.adMono).foregroundStyle(Palette.ink2)
        } else if model.routeHistory == nil {
          Text("Loading route history…").font(.adMono).foregroundStyle(Palette.ink2)
        }
      }
      .foregroundStyle(Palette.ink)
    }
  }

  private func chart(now: Date) -> some View {
    HStack(alignment: .top, spacing: 6) {
      VStack(spacing: 0) {
        Color.clear.frame(height: 32)
        ZStack(alignment: .topTrailing) {
          ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
            Text(hour == 24 ? "24" : String(format: "%02d", hour))
              .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Palette.ink3)
              .offset(y: min(max(gridHeight * CGFloat(hour) / 24 - 5, 0), gridHeight - 11))
          }
        }.frame(width: 22, height: gridHeight, alignment: .topTrailing)
      }
      ForEach(RouteTimeline.days(now: now), id: \.self) { day in
        VStack(spacing: 5) {
          VStack(spacing: 1) {
            Text(day.formatted(.dateTime.weekday(.abbreviated)))
            Text(day.formatted(.dateTime.day())).fontWeight(.semibold)
          }
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundStyle(Calendar.current.isDateInToday(day) ? Palette.accent : Palette.ink2)
          .frame(height: 27)
          dayColumn(day, now: now)
        }
      }
    }
    .padding(.bottom, 5)
  }

  private func dayColumn(_ day: Date, now: Date) -> some View {
    let blocks = RouteTimeline.blocks(model.routeHistory?.intervals ?? [], day: day)
    let departures = RouteTimeline.blocks(model.routeHistory?.departureIntervals ?? [], day: day)
    return GeometryReader { geo in
      ZStack(alignment: .topLeading) {
        Rectangle().fill(Color.theme(light: 0x2E312B, dark: 0xFFFFFF, lightAlpha: 0.04, darkAlpha: 0.035))
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
          ZStack {
            color(block.route)
            if block.route == "no_route_detected" { HistoryStripes(diagonal: true) }
          }
            .frame(height: max(0.5, gridHeight * block.height - 1))
            .offset(y: gridHeight * block.top)
            .accessibilityLabel(description(block))
        }
        ForEach(Array(departures.enumerated()), id: \.offset) { _, block in
          Rectangle().fill(Color.yellow)
            .frame(width: 4, height: max(0.5, gridHeight * block.height))
            .offset(x: max(0, geo.size.width - 4), y: gridHeight * block.top)
            .accessibilityLabel(description(block))
        }
        ForEach([6, 12, 18], id: \.self) { hour in
          Path { path in
            path.move(to: .zero); path.addLine(to: CGPoint(x: geo.size.width, y: 0))
          }.stroke(Palette.hairline, style: StrokeStyle(lineWidth: 0.5, dash: [2, 2])).frame(height: 1)
            .offset(y: gridHeight * CGFloat(hour) / 24)
        }
        if Calendar.current.isDate(day, inSameDayAs: now) {
          let parts = Calendar.current.dateComponents([.hour, .minute], from: now)
          let fraction = Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) / 1440
          HistoryStripes(diagonal: false)
            .frame(height: gridHeight * (1 - fraction)).offset(y: gridHeight * fraction)
          Rectangle().fill(Palette.accent).frame(height: 2)
            .shadow(color: Palette.accent, radius: 3)
            .offset(y: gridHeight * fraction - 1)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 4))
      .contentShape(Rectangle())
      .onContinuousHover { phase in
        switch phase {
        case .active(let point):
          let fraction = point.y / gridHeight
          let candidates = point.x >= geo.size.width - 4 ? departures : blocks
          if let block = candidates.last(where: { fraction >= $0.top && fraction < $0.top + $0.height }) {
            hovered = description(block)
          } else {
            hovered = "\(day.formatted(.dateTime.month(.abbreviated).day())) · \(day.addingTimeInterval(fraction * 86400) > now ? "not yet" : "no classification")"
          }
        case .ended: hovered = nil
        }
      }
    }
    .frame(height: gridHeight)
  }

  private var historyKey: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 14) {
        HStack(spacing: 5) {
          ZStack { color("no_route_detected"); HistoryStripes(diagonal: true) }
            .frame(width: 10, height: 10).clipShape(RoundedRectangle(cornerRadius: 2))
          Text("no route")
        }
        HStack(spacing: 5) {
          HistoryStripes(diagonal: false).frame(width: 10, height: 10)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Palette.hairline, lineWidth: 0.5))
          Text("not yet")
        }
      }
      HStack(spacing: 5) {
        Color.yellow.frame(width: 3, height: 9)
        Text("south → east departures")
      }
    }.font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.ink2)
      .help("Local time · blank past hours have no observations or classification")
  }

  private var monthly: some View {
    let data = model.routeHistory
    let shares = routes.compactMap { route in data?.shares.first { $0.route == route && $0.seconds > 0 } }
    return VStack(alignment: .leading, spacing: 11) {
      HStack {
        Text("LAST 30 DAYS").font(.system(size: 9.5, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.ink3)
        Spacer()
        Text("share of classified time").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.ink2)
      }
      GeometryReader { geo in
        HStack(spacing: 2) {
          ForEach(shares) { share in
            color(share.route).frame(width: max(0, geo.size.width - CGFloat(max(0, shares.count - 1)) * 2) * share.percent / 100)
              .accessibilityLabel("\(label(share.route)): \(share.percent.formatted(.number.precision(.fractionLength(1)))) percent")
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Palette.fill)
        .clipShape(RoundedRectangle(cornerRadius: 5))
      }.frame(height: 10)
      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
        GridRow {
          groupLabel("NOISY")
          shareLabel(routes[0]); shareLabel(routes[1])
        }
        GridRow {
          groupLabel("QUIET")
          shareLabel(routes[2]); shareLabel(routes[3])
        }
      }
      if let data {
        let coverage = Double(data.classifiedSeconds) * 100 / Double(max(data.windowSeconds, 1))
        Text("\((Double(data.classifiedSeconds) / 3600).formatted(.number.precision(.fractionLength(1))))h classified · \(coverage.formatted(.number.precision(.fractionLength(1))))% coverage")
          .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.ink3)
      }
    }
  }

  private func groupLabel(_ text: String) -> some View {
    Text(text).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.ink3)
  }

  private func shareLabel(_ route: String) -> some View {
    let share = model.routeHistory?.shares.first { $0.route == route }
    return HStack(spacing: 5) {
      RoundedRectangle(cornerRadius: 2).fill(color(route)).frame(width: 8, height: 8)
      Text(label(route)).font(.system(size: 11.5)).foregroundStyle(Palette.ink2)
      Text((model.routeHistory?.classifiedSeconds ?? 0) > 0
        ? "\((share?.percent ?? 0).formatted(.number.precision(.fractionLength(1))))%" : "—")
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
    }.lineLimit(1).fixedSize()
  }

  private func color(_ route: String) -> Color {
    switch route {
    case "low_approach": return Color.theme(light: 0xE5850F, dark: 0xFF9A2E)
    case "high_approach": return Color.theme(light: 0x2F93DC, dark: 0x4CB8FF)
    case "river_approach": return Color.theme(light: 0x5F9A6C, dark: 0x4A9A78)
    case "direct_approach": return Color.theme(light: 0x8C80B8, dark: 0x7B6CAE)
    case "no_route_detected": return Color.theme(light: 0xD3D5C9, dark: 0x223447)
    default: return Palette.fill
    }
  }

  private func label(_ route: String) -> String {
    switch route {
    case "south_then_east": return "Departures south → east"
    case "low_approach": return "Low"
    case "high_approach": return "High"
    case "no_route_detected": return "No route detected"
    case "direct_approach": return "Direct"
    default: return "River"
    }
  }

  private func description(_ block: RouteTimeline.Block) -> String {
    "\(label(block.route)) · \(block.start.formatted(.dateTime.month(.abbreviated).day())) · \(block.start.formatted(date: .omitted, time: .shortened))–\(block.end.formatted(date: .omitted, time: .shortened))"
  }
}

private struct HistoryStripes: View {
  let diagonal: Bool
  var body: some View {
    Canvas { context, size in
      var path = Path()
      if diagonal {
        for x in stride(from: -size.height, through: size.width, by: 5) {
          path.move(to: CGPoint(x: x, y: size.height))
          path.addLine(to: CGPoint(x: x + size.height, y: 0))
        }
      } else {
        for y in stride(from: 5.0, through: size.height, by: 6) {
          path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
        }
      }
      context.stroke(path, with: .color(Color.theme(light: 0x2E312B, dark: 0xFFFFFF,
        lightAlpha: diagonal ? 0.10 : 0.08, darkAlpha: diagonal ? 0.07 : 0.06)), lineWidth: diagonal ? 1.5 : 1)
    }.clipped().accessibilityHidden(true)
  }
}
