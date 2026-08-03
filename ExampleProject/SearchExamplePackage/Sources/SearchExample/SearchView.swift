import Lattice
import SwiftUI

struct SearchView: View {
    @Bindable private var viewModel: ViewModel<SearchState, SearchEvent>

    init(viewModel: ViewModel<SearchState, SearchEvent>) {
        self.viewModel = viewModel
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    """
                    This view provides a simple example on how to debounce
                    search events with Lattice.

                    Data Flow:
                     - Keystrokes are debounced by 300ms
                     - When you stop typing an API Request is made to load locations
                     - Tapping on a row loads weather
                    """
                )
                .padding()

                HStack {
                    Image(systemName: "magnifyingglass")

                    TextField(
                        "New York, San Francisco, ...",
                        text: $viewModel.results.query.sending(\.search.query, default: "")
                    )
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                }
                .padding(.horizontal, 16)

                // Case-accessor projection read: `results` is the `.results` case's payload,
                // or nil when the state is `.noResults`.
                if let content = viewModel.results, !content.results.isEmpty {
                    listView(content)
                }

                Spacer()
            }
            .navigationTitle("Search")
        }
    }

    private func listView(_ content: FeatureProjection<SearchState.ResultState>) -> some View {
        List(content.results.ids, id: \.self) { id in
            if let listItem = content.results[id: id] {
                VStack(alignment: .leading) {
                    Button {
                        viewModel.sendViewEvent(.locationTapped(id: listItem.id))
                    } label: {
                        HStack {
                            Text(listItem.name)

                            if listItem.isLoading {
                                ProgressView()
                            }
                        }
                    }

                    if let forecasts = listItem.forecasts {
                        forecastView(forecasts)
                    }
                }
            }
        }
    }

    private func forecastView(_ forecasts: [String]) -> some View {
        VStack(alignment: .leading) {
            ForEach(forecasts, id: \.self) { day in
                Text(day)
            }
        }
        .padding(.leading, 16)
    }
}
