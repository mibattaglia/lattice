//
//  ContentView.swift
//  ExampleProject
//
//  Created by Michael Battaglia on 2/5/26.
//

import SearchExample
import SwiftUI
import TodosExample

struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                ForEach(Example.allCases) { example in
                    NavigationLink(example.title) {
                        example.destinationView
                            .navigationTitle(example.navigationTitle)
                            .navigationBarTitleDisplayMode(.inline)
                    }
                }
            }
            .navigationTitle("Examples")
        }
    }
}

#Preview {
    ContentView()
}

private enum Example: String, CaseIterable, Identifiable {
    case search
    case todos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search:
            "Search Example"
        case .todos:
            "Todos Example"
        }
    }

    var navigationTitle: String {
        switch self {
        case .search:
            "Search"
        case .todos:
            "Todos"
        }
    }

    @ViewBuilder
    var destinationView: some View {
        switch self {
        case .search:
            SearchExampleAppView()
        case .todos:
            TodosExampleAppView()
        }
    }
}
