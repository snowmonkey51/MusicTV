import SwiftUI

/// Root view for the tvOS app. Two states:
///
/// 1. **Landing screen** — shown before a library is connected and playback starts.
///    Displays a welcome message and discovered Bonjour libraries to connect to.
///
/// 2. **Full-screen player** — shown once connected and playing.
///    AVPlayerViewController fills the screen. All UI is accessed via
///    Siri Remote gestures (swipe up for overlay, swipe down for info, etc.).
struct TVContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackEngine.self) private var engine

    var body: some View {
        ZStack {
            if appState.hasStarted {
                // Full-screen player
                TVVideoPlayerView(
                    player: engine.player,
                    appState: appState,
                    engine: engine
                )
                .ignoresSafeArea()
                .transition(.opacity)
            } else {
                // Landing screen
                TVLandingView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: appState.hasStarted)
    }
}

// MARK: - Landing Screen

private struct TVLandingView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackEngine.self) private var engine

    var body: some View {
        VStack(spacing: 40) {
            Spacer()

            // App branding
            VStack(spacing: 16) {
                Image(systemName: "play.tv")
                    .font(.system(size: 80))
                    .foregroundStyle(.tint)

                Text("MusicTV")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Connect to a library to start watching")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            // Library list
            VStack(spacing: 16) {
                if appState.libraryBrowser.discoveredLibraries.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()

                        Text("Searching for MusicTV libraries on your network…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text("Make sure a Mac with MusicTV is sharing its library.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 20)
                } else {
                    ForEach(appState.libraryBrowser.discoveredLibraries) { library in
                        Button(action: { connectAndPlay(library) }) {
                            HStack {
                                Image(systemName: "tv.and.hifispeaker.fill")
                                    .font(.title2)

                                Text(library.name)
                                    .font(.title3)

                                Spacer()

                                if appState.connectedNetworkLibrary?.id == library.id {
                                    if appState.isLoadingNetworkLibrary {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                            .font(.title3)
                                    }
                                }
                            }
                            .padding(.horizontal, 32)
                            .padding(.vertical, 16)
                        }
                        .buttonStyle(.card)
                    }
                }
            }
            .frame(maxWidth: 600)

            Spacer()
        }
    }

    private func connectAndPlay(_ library: DiscoveredLibrary) {
        appState.connectToNetworkLibrary(library)

        Task {
            // Wait for library to finish loading
            while appState.isLoadingNetworkLibrary {
                try? await Task.sleep(for: .milliseconds(200))
            }
            if !appState.playlist.isEmpty {
                appState.hasStarted = true
                appState.currentIndex = 0
                engine.startPlayback()
            }
        }
    }
}
