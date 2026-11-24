import SwiftData
import SwiftUI

/// The weeks shown for a month, padded with neighbouring days so every row is complete.
struct MonthGrid: Equatable {
    var month: Date
    var weeks: [[Date]]

    init(containing date: Date, calendar: Calendar) {
        let first = calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: first)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        let dayCount = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        let weekCount = (offset + dayCount + 6) / 7
        let start = calendar.date(byAdding: .day, value: -offset, to: first) ?? first
        month = first
        weeks = (0..<weekCount).map { week in
            (0..<7).compactMap { calendar.date(byAdding: .day, value: week * 7 + $0, to: start) }
        }
    }

    static func weekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    static func weekdayNames(calendar: Calendar) -> [String] {
        let symbols = calendar.standaloneWeekdaySymbols
        return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }
}

struct CalendarGridView: View {
    let meetings: [Meeting]
    @Binding var selectedDay: Date

    @Environment(\.calendar) private var calendar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visibleMonth = Date.now
    @Namespace private var selectionNamespace

    /// The selection highlight glides between days; with Reduce Motion it just jumps.
    private var selectionAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.2)
    }

    private var counts: [Date: Int] {
        Dictionary(meetings.map { (calendar.startOfDay(for: $0.startDate), 1) }, uniquingKeysWith: +)
    }

    var body: some View {
        let grid = MonthGrid(containing: visibleMonth, calendar: calendar)
        let counts = counts
        VStack(spacing: 8) {
            header(grid)
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    ForEach(Array(zip(MonthGrid.weekdaySymbols(calendar: calendar), MonthGrid.weekdayNames(calendar: calendar))), id: \.1) { symbol, name in
                        Text(symbol)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(name)
                    }
                }
                ForEach(grid.weeks, id: \.first) { week in
                    GridRow {
                        ForEach(week, id: \.self) { day in
                            DayCell(
                                day: day,
                                inMonth: calendar.isDate(day, equalTo: grid.month, toGranularity: .month),
                                isToday: calendar.isDateInToday(day),
                                isSelected: calendar.isDate(day, inSameDayAs: selectedDay),
                                count: counts[calendar.startOfDay(for: day)] ?? 0,
                                selectionNamespace: selectionNamespace
                            ) {
                                selectedDay = calendar.startOfDay(for: day)
                            }
                        }
                    }
                }
            }
            .focusable()
            .onMoveCommand(perform: move)
            .animation(selectionAnimation, value: selectedDay)
        }
        .padding(12)
        .onAppear { visibleMonth = selectedDay }
        .onChange(of: selectedDay) { _, day in
            if !calendar.isDate(day, equalTo: visibleMonth, toGranularity: .month) { visibleMonth = day }
        }
    }

    private func header(_ grid: MonthGrid) -> some View {
        HStack {
            Text(grid.month, format: .dateTime.month(.wide).year())
                .font(.title3.weight(.semibold))
                .contentTransition(.numericText())
            Spacer()
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous Month")
                .help("Previous Month")
            Button("Today") {
                withAnimation(selectionAnimation) {
                    selectedDay = calendar.startOfDay(for: .now)
                    visibleMonth = .now
                }
            }
            .disabled(calendar.isDateInToday(selectedDay) && calendar.isDate(visibleMonth, equalTo: .now, toGranularity: .month))
            .help("Go to Today")
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("Next Month")
                .help("Next Month")
        }
        .buttonStyle(.borderless)
    }

    private func shiftMonth(_ delta: Int) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
            visibleMonth = calendar.date(byAdding: .month, value: delta, to: visibleMonth) ?? visibleMonth
        }
    }

    private func move(_ direction: MoveCommandDirection) {
        let days: Int
        switch direction {
        case .left: days = -1
        case .right: days = 1
        case .up: days = -7
        case .down: days = 7
        @unknown default: return
        }
        if let next = calendar.date(byAdding: .day, value: days, to: selectedDay) {
            selectedDay = calendar.startOfDay(for: next)
        }
    }
}

private struct DayCell: View {
    let day: Date
    let inMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let count: Int
    let selectionNamespace: Namespace.ID
    let action: () -> Void

    @Environment(\.calendar) private var calendar
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(day, format: .dateTime.day())
                    .monospacedDigit()
                    .foregroundStyle(isToday ? AnyShapeStyle(.white) : inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .frame(width: 26, height: 26)
                    .background(isToday ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: .circle)
                Circle()
                    .fill(count > 0 ? Color.accentColor : .clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .background {
                // One shared highlight that moves between cells instead of fading per cell.
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.selection.opacity(0.35))
                        .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.primary.opacity(0.06))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .focusable(false)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var label: String {
        let date = day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        let recordings = count == 0 ? String(localized: "no recordings") : String(localized: "\(count) recordings")
        return "\(date), \(recordings)"
    }
}

#if DEBUG
#Preview {
    @Previewable @State var day = Calendar.current.startOfDay(for: .now)
    @Previewable @State var model = AppModel.preview(samples: true)
    QueriedMeetings { meetings in
        CalendarGridView(meetings: meetings, selectedDay: $day)
    }
    .modelContainer(model.container)
    .frame(width: 340)
}
#endif
