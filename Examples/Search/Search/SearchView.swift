import SwiftUI
import UnoArchitecture

struct SearchView: View {

    @ObservedObject private var viewModel: AnyViewModel<SearchEvent, SearchViewState>

    init(viewModel: AnyViewModel<SearchEvent, SearchViewState>) {
        self.viewModel = viewModel
    }

    @State var search = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    """
                    This view provides a simple example on how to debounced
                    search events with Uno. 

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
                        text: $search
                    )
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: search) { oldValue, newValue in
                        viewModel.sendViewEvent(.search(.query(newValue)))
                    }
                }
                .padding(.horizontal, 16)

                switch viewModel.viewState {
                case .none:
                    EmptyView()
                case let .loaded(listContent):
                    listView(listContent)
                        .transition(.opacity)
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

private final class MockViewModel: ViewModel {
    @Published private(set) var viewState = SearchViewState.loaded(
        SearchListContent(
            listItems: [
                SearchListItem(id: "1", name: "New York", isLoading: true),
                SearchListItem(
                    id: "2", name: "Yorkshire",
                    weather: Weather(forecasts: [
                        "Today, 18.4 - 30.5",
                        "Sunday, 20.0 - 29.0",
                        "Monday, 18.4 - 30.5",
                        "Tuesday, 18.4 - 30.5",
                    ])),
                SearchListItem(id: "3", name: "Amsterdam"),
                SearchListItem(id: "4", name: "San Francisco"),
            ]
        )
    )

    func sendViewEvent(_ event: SearchEvent) {}
}

#Preview {
    SearchView(viewModel: MockViewModel().erased())
}
