//
//  ContentView.swift
//  ExampleProject
//
//  Created by Michael Battaglia on 2/5/26.
//

import SearchExample
import SwiftUI
import TimerLeakExample
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
    case timerLeak

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search:
            "Search Example"
        case .todos:
            "Todos Example"
        case .timerLeak:
            "Timer Leak Example"
        }
    }

    var navigationTitle: String {
        switch self {
        case .search:
            "Search"
        case .todos:
            "Todos"
        case .timerLeak:
            "Timer Leak"
        }
    }

    @ViewBuilder
    var destinationView: some View {
        switch self {
        case .search:
            SearchExampleAppView()
        case .todos:
            TodosExampleAppView()
        case .timerLeak:
            TimerLeakExampleAppView()
        }
    }
}
