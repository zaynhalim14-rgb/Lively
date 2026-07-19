//
//  LivelyApp.swift
//  Lively
//
//  App entry point. A single editor model drives the whole session:
//  HomeView until a Live Photo is loaded, EditorView afterwards.
//

import SwiftUI

@main
struct LivelyApp: App {
    @State private var model = EditorViewModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(FlatTheme.accent)
                .fontDesign(.rounded)
        }
    }
}

/// Switches between the landing screen and the editor with a flat cross-fade.
struct RootView: View {
    @Environment(EditorViewModel.self) private var model

    var body: some View {
        ZStack {
            FlatTheme.background.ignoresSafeArea()
            if model.hasSource {
                EditorView()
                    .transition(.opacity)
            } else {
                HomeView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.hasSource)
    }
}
