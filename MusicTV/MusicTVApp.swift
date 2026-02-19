//
//  MusicTVApp.swift
//  MusicTV
//
//  Created by aaron bevill on 2/15/26.
//

import SwiftUI

@main
struct MusicTVApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()
    @State private var engine = PlaybackEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(engine)
                .onAppear {
                    appDelegate.engine = engine
                    appDelegate.appState = appState
                }
        }
        .defaultSize(width: 1280, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Library") {
                    appState.refreshLibrary()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var engine: PlaybackEngine?
    var appState: AppState?
    private var hasBeenActive = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // On first activation (after launch), restart the browser so it picks up
        // services that may not have been visible before the user granted
        // Local Network permission. Skip subsequent activations to avoid
        // unnecessary restarts when just switching windows.
        if !hasBeenActive {
            hasBeenActive = true
            // Small delay to let the permission system settle
            Task {
                try? await Task.sleep(for: .seconds(1))
                appState?.libraryBrowser.restartBrowsing()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.teardown()
        appState?.libraryServer.stop()
        appState?.libraryBrowser.stopBrowsing()
    }
}
