import SwiftUI
import UnoArchitecture

struct TimelineView: View {
    @StateObject private var viewModel: AnyViewModel<TimelineEvent, TimelineViewState>

    init(healthKitReader: HealthKitReader) {
        _viewModel = StateObject(
            wrappedValue: TimelineViewModel(
                interactor: TimelineInteractor(healthKitReader: healthKitReader)
                    .eraseToAnyInteractor(),
                viewStateReducer: TimelineViewStateReducer()
                    .eraseToAnyReducer()
            )
            .erased()
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.viewState {
                case .loading:
                    loadingView

                case .loaded(let content):
                    timelineList(content)

                case .error(let error):
                    errorView(error)
                }
            }
            .background(Color.black)
            .navigationTitle("Health Timeline")
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
            Text("Loading health data...")
                .font(.subheadline)
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private func timelineList(_ content: TimelineListContent) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(content.sections) { section in
                    sectionView(section)
                }
            }
            .padding()
        }
        .background(Color.black)
    }

    private func sectionView(_ section: TimelineSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.title)
                .font(.title2.bold())
                .foregroundStyle(.white)

            VStack(spacing: 0) {
                ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                    switch item {
                    case .workout(let workout):
                        NavigationLink {
                            WorkoutDetailView(viewState: workout.detailViewState)
                        } label: {
                            WorkoutCell(workout: workout)
                        }
                        .buttonStyle(.plain)

                    case .recovery(let recovery):
                        NavigationLink {
                            RecoveryDetailView(viewState: recovery.detailViewState)
                        } label: {
                            RecoveryCell(recovery: recovery)
                        }
                        .buttonStyle(.plain)
                    }

                    if index < section.items.count - 1 {
                        Divider()
                            .background(Color.gray.opacity(0.3))
                    }
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemGray6).opacity(0.15))
            )
        }
    }

    private func errorView(_ error: ErrorContent) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("Unable to Load Data")
                .font(.title3.bold())
                .foregroundStyle(.white)

            Text(error.message)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)

            if error.canRetry {
                Button("Try Again") {
                    viewModel.sendViewEvent(.onAppear)
                }
                .font(.headline)
                .foregroundStyle(.black)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.white)
                .clipShape(Capsule())
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
