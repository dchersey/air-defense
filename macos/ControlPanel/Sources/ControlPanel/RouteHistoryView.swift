import SwiftUI

struct RouteHistoryView: View {
  let model: StatusModel
  let onBack: () -> Void
  @State private var hovered: String?
  private let gridHeight: CGFloat = 240
  private let routes = ["low_approach", "high_approach", "river_approach"]

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Button(action: onBack) { Image(systemName: "chevron.left") }
            .buttonStyle(.plain).accessibilityLabel("Back")
          Text("Route history").font(.adTitle)
          Spacer()
          Text("7 DAYS").font(.adMono).foregroundStyle(Palette.ink3)
        }
        Text("Arrival routes · time of day")
          .font(.adMono).foregroundStyle(Palette.ink2)
        chart(now: context.date)
        Text(hovered ?? "Local time · blank = unclassified or unobserved")
          .font(.adMono).foregroundStyle(Palette.ink2)
          .frame(height: 30, alignment: .topLeading)
        Divider().overlay(Palette.hairline)
        monthly
        if model.routeHistoryError || !model.reachable {
          Text("History unavailable · showing last saved view")
            .font(.adMono).foregroundStyle(Palette.inbound)
        } else if let data = model.routeHistory, data.classifiedSeconds == 0 {
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
    HStack(alignment: .top, spacing: 5) {
      VStack(spacing: 0) {
        Color.clear.frame(height: 32)
        ZStack(alignment: .topTrailing) {
          ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
            Text(hour == 24 ? "24" : String(format: "%02d", hour))
              .font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.ink3)
              .offset(y: gridHeight * CGFloat(hour) / 24 - 5)
          }
        }.frame(width: 19, height: gridHeight, alignment: .topTrailing)
      }
      ForEach(RouteTimeline.days(now: now), id: \.self) { day in
        VStack(spacing: 5) {
          VStack(spacing: 1) {
            Text(day.formatted(.dateTime.weekday(.abbreviated)))
            Text(day.formatted(.dateTime.day()))
          }
          .font(.system(size: 9, design: .monospaced))
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
    return GeometryReader { _ in
      ZStack(alignment: .topLeading) {
        Rectangle().fill(Palette.fill)
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
          Rectangle().fill(color(block.route).opacity(0.8))
            .frame(height: max(0.5, gridHeight * block.height))
            .offset(y: gridHeight * block.top)
            .accessibilityLabel(description(block))
        }
        ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
          Rectangle().fill(Palette.hairline).frame(height: 1)
            .offset(y: gridHeight * CGFloat(hour) / 24)
        }
        if Calendar.current.isDate(day, inSameDayAs: now) {
          let parts = Calendar.current.dateComponents([.hour, .minute], from: now)
          let fraction = Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) / 1440
          Rectangle().fill(Palette.ink2).frame(height: 1)
            .offset(y: gridHeight * fraction)
        }
      }
      .clipped()
      .contentShape(Rectangle())
      .onContinuousHover { phase in
        switch phase {
        case .active(let point):
          let fraction = point.y / gridHeight
          if let block = blocks.last(where: { fraction >= $0.top && fraction < $0.top + $0.height }) {
            hovered = description(block)
          } else {
            hovered = "\(day.formatted(.dateTime.month(.abbreviated).day())) · no classification"
          }
        case .ended: hovered = nil
        }
      }
    }
    .frame(height: gridHeight)
  }

  private var monthly: some View {
    let data = model.routeHistory
    return VStack(alignment: .leading, spacing: 9) {
      HStack {
        Text("LAST 30 DAYS").font(.adMono)
        Spacer()
        Text("Share of classified time").font(.adMono).foregroundStyle(Palette.ink3)
      }
      GeometryReader { geo in
        HStack(spacing: 0) {
          ForEach(data?.shares ?? []) { share in
            if share.seconds > 0 {
              color(share.route).frame(width: geo.size.width * share.percent / 100)
                .accessibilityLabel("\(label(share.route)): \(share.percent.formatted(.number.precision(.fractionLength(1)))) percent")
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Palette.fill)
        .clipShape(RoundedRectangle(cornerRadius: 4))
      }.frame(height: 14)
      HStack(spacing: 8) {
        ForEach(routes, id: \.self) { route in
          let share = data?.shares.first { $0.route == route }
          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
              Circle().fill(color(route)).frame(width: 5, height: 5)
              Text(label(route))
            }
            Text((data?.classifiedSeconds ?? 0) > 0
                 ? "\((share?.percent ?? 0).formatted(.number.precision(.fractionLength(1))))%" : "—")
              .foregroundStyle(Palette.ink)
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
      }.font(.adMono).foregroundStyle(Palette.ink2)
      if let data {
        let coverage = Double(data.classifiedSeconds) * 100 / Double(max(data.windowSeconds, 1))
        Text("\((Double(data.classifiedSeconds) / 3600).formatted(.number.precision(.fractionLength(1))))h classified · \(coverage.formatted(.number.precision(.fractionLength(1))))% coverage")
          .font(.adMono).foregroundStyle(Palette.ink3)
      }
    }
  }

  private func color(_ route: String) -> Color {
    switch route {
    case "low_approach": return Palette.inbound
    case "high_approach": return Palette.accent
    default: return Palette.go
    }
  }

  private func label(_ route: String) -> String {
    switch route {
    case "low_approach": return "Low"
    case "high_approach": return "High"
    default: return "River"
    }
  }

  private func description(_ block: RouteTimeline.Block) -> String {
    "\(label(block.route)) · \(block.start.formatted(.dateTime.month(.abbreviated).day())) · \(block.start.formatted(date: .omitted, time: .shortened))–\(block.end.formatted(date: .omitted, time: .shortened))"
  }
}
