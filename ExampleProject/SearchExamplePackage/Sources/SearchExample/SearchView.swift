import Lattice
import SwiftUI

struct SearchView: View {
    @Bindable private var viewModel: ViewModel<Feature<SearchEvent, SearchDomainState, SearchViewState>>

    init(viewModel: ViewModel<Feature<SearchEvent, SearchDomainState, SearchViewState>>) {
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
                        text: $viewModel.loaded.query.sending(\.search.query)
                    )
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                }
                .padding(.horizontal, 16)

                switch viewModel.viewState {
                case .none:
                    EmptyView()
                case .loaded(let listContent):
                    if listContent.listItems.isEmpty {
                        EmptyView()
                    } else {
                        listView(listContent)
                            .transition(.opacity)
                    }
                }

                Spacer()
            }
            .animation(.default, value: viewModel.viewState)
            .navigationTitle("Search")
        }
    }

    private func listView(_ content: SearchListContent) -> some View {
        List(content.listItems) { listItem in
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

                if let weather = listItem.weather {
                    weatherView(weather)
                }
            }
        }
    }

    private func weatherView(_ weather: Weather) -> some View {
        VStack(alignment: .leading) {
            ForEach(weather.forecasts, id: \.self) { day in
                Text(day)
            }
        }
        .padding(.leading, 16)
    }
}
