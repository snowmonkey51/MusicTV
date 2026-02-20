import SwiftUI

@main
struct MusicTVApp: App {
    @State private var appState = AppState()
    @State private var engine = PlaybackEngine()

    var body: some Scene {
        WindowGroup {
            TVContentView()
                .environment(appState)
                .environment(engine)
                .onAppear {
                    engine.attach(to: appState)
                }
        }
    }
}
