import SwiftUI
import Charts

struct TrendChartCard: View {
    let chartData: ChartData
    let chartType: ChartType

    @State private var selectedDate: Date?
    @State private var scrollPosition: Date = Date()

    private let visibleDays: TimeInterval = 14 * 24 * 60 * 60

    enum ChartType {
        case bar
        case line
        case area
    }

    private var selectedPoint: ChartDataPoint? {
        guard let selectedDate else { return nil }
        let calendar = Calendar.current
        let targetDay = calendar.startOfDay(for: selectedDate)
        return chartData.pointsByDay[targetDay]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerView
            chartView
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemGray6).opacity(0.15))
        )
        .onAppear {
            initializeScrollPosition()
        }
    }

    private func initializeScrollPosition() {
        if let lastDate = chartData.dataPoints.last?.date {
            let calendar = Calendar.current
            scrollPosition = calendar.date(byAdding: .day, value: -3, to: lastDate) ?? lastDate
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(chartData.title)
                .font(.headline)
                .foregroundStyle(.white)

            Text(selectedPoint?.label ?? chartData.averageValue)
                .font(.system(.title, design: .rounded))
                .fontWeight(.bold)
                .foregroundStyle(chartData.color)
                .contentTransition(.numericText())

            Text(selectedPoint.map { $0.date.formatted(.dateTime.month().day().year()) } ?? chartData.unit)
                .font(.caption)
                .foregroundStyle(.gray)
        }
        .animation(.easeInOut(duration: 0.15), value: selectedPoint?.id)
    }

    @ViewBuilder
    private var chartView: some View {
        if chartData.hasData {
            switch chartType {
            case .bar:
                barChart
            case .line:
                lineChart
            case .area:
                areaChart
            }
        } else {
            emptyChart
        }
    }

    private var barChart: some View {
        Chart(chartData.dataPoints) { point in
            BarMark(
                x: .value("Date", point.date, unit: .day),
                y: .value("Value", point.value)
            )
            .foregroundStyle(
                selectedPoint?.id == point.id
                    ? chartData.color
                    : (selectedPoint != nil ? chartData.color.opacity(0.4) : chartData.color)
            )
            .cornerRadius(4)

            if let selected = selectedPoint, selected.id == point.id {
                RuleMark(x: .value("Date", point.date, unit: .day))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: visibleDays)
        .chartScrollPosition(x: $scrollPosition)
        .chartScrollTargetBehavior(
            .valueAligned(unit: 7)
        )
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine()
                    .foregroundStyle(Color.gray.opacity(0.3))
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .foregroundStyle(.gray)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine()
                    .foregroundStyle(Color.gray.opacity(0.3))
                AxisValueLabel()
                    .foregroundStyle(.gray)
            }
        }
        .frame(height: 180)
    }

    private var lineChart: some View {
        Chart(chartData.dataPoints) { point in
            LineMark(
                x: .value("Date", point.date, unit: .day),
                y: .value("Value", point.value)
            )
            .foregroundStyle(chartData.color)
            .lineStyle(StrokeStyle(lineWidth: 3))
            .interpolationMethod(.catmullRom)

            PointMark(
                x: .value("Date", point.date, unit: .day),
                y: .value("Value", point.value)
            )
            .foregroundStyle(
                selectedPoint?.id == point.id ? .white : chartData.color
            )
            .symbolSize(selectedPoint?.id == point.id ? 80 : (point.value > 0 ? 40 : 0))

            if let selected = selectedPoint, selected.id == point.id {
                RuleMark(x: .value("Date", point.date, unit: .day))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: visibleDays)
        .chartScrollPosition(x: $scrollPosition)
        .chartScrollTargetBehavior(
            .valueAligned(
                matching: DateComponents(weekday: 1),
                majorAlignment: .matching(DateComponents(weekday: 1))
            )
        )
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine()
                    .foregroundStyle(Color.gray.opacity(0.3))
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .foregroundStyle(.gray)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine()
                    .foregroundStyle(Color.gray.opacity(0.3))
                AxisValueLabel()
                    .foregroundStyle(.gray)
            }
        }
        .frame(height: 180)
    }

    private var areaChart: some View {
        Chart(chartData.dataPoints) { point in
            AreaMark(
                x: .value("Date", point.date, unit: .day),
                y: .value("Value", point.value)
            )
            .foregroundStyle(
                Gradient(colors: [chartData.color, chartData.color.opacity(0.3)])
            )
            .interpolationMethod(.catmullRom)

            LineMark(
                x: .value("Date", point.date, unit: .day),
                y: .value("Value", point.value)
            )
            .foregroundStyle(chartData.color)
            .lineStyle(StrokeStyle(lineWidth: 2))
            .interpolationMethod(.catmullRom)

            if let selected = selectedPoint, selected.id == point.id {
                PointMark(
                    x: .value("Date", point.date, unit: .day),
                    y: .value("Value", point.value)
                )
                .foregroundStyle(.white)
                .symbolSize(80)

                RuleMark(x: .value("Date", point.date, unit: .day))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: visibleDays)
        .chartScrollPosition(x: $scrollPosition)
        .chartScrollTargetBehavior(
            .valueAligned(
                matching: DateComponents(weekday: 1),
                majorAlignment: .matching(DateComponents(weekday: 1))
            )
        )
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine()
                    .foregroundStyle(Color.gray.opacity(0.3))
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .foregroundStyle(.gray)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine()
                    .foregroundStyle(Color.gray.opacity(0.3))
                AxisValueLabel()
                    .foregroundStyle(.gray)
            }
        }
        .frame(height: 180)
    }

    private var emptyChart: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 32))
                .foregroundStyle(.gray)
            Text("No data available")
                .font(.subheadline)
                .foregroundStyle(.gray)
        }
        .frame(height: 180)
        .frame(maxWidth: .infinity)
    }
}
