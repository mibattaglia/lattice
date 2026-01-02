import SwiftUI
import Charts
import UnoArchitecture

struct TrendsView: View {
    @State private var viewModel: ViewModel<TrendsEvent, TrendsDomainState, TrendsViewState>

    init(healthKitReader: HealthKitReader) {
        _viewModel = State(
            wrappedValue: ViewModel(
                initialValue: TrendsViewState.loading,
                TrendsInteractor(healthKitReader: healthKitReader)
                    .eraseToAnyInteractor(),
                TrendsViewStateReducer()
                    .eraseToAnyReducer()
            )
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.viewState {
                case .loading:
                    loadingView

                case .loaded(let content):
                    trendsContent(content)

                case .error(let error):
                    errorView(error)
                }
            }
            .background(Color.black)
            .navigationTitle("Trends")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                if case .loaded(let content) = viewModel.viewState {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Text(content.lastUpdated)
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }
                }
            }
        }
        .onAppear {
            viewModel.sendViewEvent(.onAppear)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)
            Text("Loading trends...")
                .font(.subheadline)
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private func trendsContent(_ content: TrendsContent) -> some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                sectionHeader("Activity")

                TrendChartCard(
                    chartData: content.workoutDurationChart,
                    chartType: .bar
                )
                TrendChartCard(
                    chartData: content.caloriesChart,
                    chartType: .bar
                )

                sectionHeader("Recovery")

                TrendChartCard(
                    chartData: content.sleepChart,
                    chartType: .area
                )

                sectionHeader("Vitals")

                TrendChartCard(
                    chartData: content.hrvChart,
                    chartType: .line
                )
                TrendChartCard(
                    chartData: content.rhrChart,
                    chartType: .line
                )
                TrendChartCard(
                    chartData: content.respiratoryRateChart,
                    chartType: .line
                )
            }
            .padding()
        }
        .background(Color.black)
        .refreshable {
            viewModel.sendViewEvent(.refresh)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.top, 8)
    }

    private func errorView(_ error: TrendsErrorContent) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("Unable to Load Trends")
                .font(.title3.bold())
                .foregroundStyle(.white)

            Text(error.message)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)

            Button("Try Again") {
                viewModel.sendViewEvent(.refresh)
            }
            .font(.headline)
            .foregroundStyle(.black)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(Color.white)
            .clipShape(Capsule())
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
