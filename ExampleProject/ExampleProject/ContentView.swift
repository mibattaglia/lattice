//
//  ContentView.swift
//  ExampleProject
//
//  Created by Michael Battaglia on 2/5/26.
//

import SearchExample
import SwiftUI

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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search:
            "Search Example"
        }
    }

    var navigationTitle: String {
        switch self {
        case .search:
            "Search"
        }
    }

    @ViewBuilder
    var destinationView: some View {
        switch self {
        case .search:
            SearchExampleAppView()
        }
    }
}
