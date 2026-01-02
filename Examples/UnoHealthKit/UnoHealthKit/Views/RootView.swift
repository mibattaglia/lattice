import SwiftUI
import UnoArchitecture

struct RootView: View {
    private let viewModel: ViewModel<RootEvent, RootDomainState, RootViewState>
    private let healthKitReader: HealthKitReader

    init(
        viewModel: ViewModel<RootEvent, RootDomainState, RootViewState>,
        healthKitReader: HealthKitReader
    ) {
        self.viewModel = viewModel
        self.healthKitReader = healthKitReader
    }

    var body: some View {
        Group {
            switch viewModel.viewState {
            case .loading:
                loadingView(message: "Checking permissions...")
            case .permissionRequired:
                permissionRequiredView
            case .requestingPermission:
                loadingView(message: "Requesting HealthKit Access...")
            case .permissionDenied:
                permissionDeniedView
            case .ready:
                TabView {
                    TimelineView(healthKitReader: healthKitReader)
                        .tabItem {
                            Label("Timeline", systemImage: "clock.fill")
                        }

                    TrendsView(healthKitReader: healthKitReader)
                        .tabItem {
                            Label("Trends", systemImage: "chart.line.uptrend.xyaxis")
                        }
                }
                .tint(.white)
            }
        }
        .onAppear {
            viewModel.sendViewEvent(.onAppear)
        }
    }

    private func loadingView(message: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(message)
                .foregroundStyle(.secondary)
        }
    }

    private var permissionRequiredView: some View {
        VStack(spacing: 24) {
            Image(systemName: "heart.text.square")
                .font(.system(size: 64))
                .foregroundStyle(.red)

            Text("HealthKit Access Required")
                .font(.title2.bold())

            Text("This app needs access to your health data to display your workouts and recovery information.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Button("Grant Access") {
                viewModel.sendViewEvent(.requestPermission)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 64))
                .foregroundStyle(.orange)

            Text("Permission Denied")
                .font(.title2.bold())

            Text("HealthKit access was denied. Please enable access in Settings to use this app.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Text("Settings > Privacy & Security > Health > UnoHealthKit")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
    }
}
