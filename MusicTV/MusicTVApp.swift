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
                .onAppear { appDelegate.engine = engine }
        }
        .defaultSize(width: 1280, height: 720)
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var engine: PlaybackEngine?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.teardown()
    }
}
