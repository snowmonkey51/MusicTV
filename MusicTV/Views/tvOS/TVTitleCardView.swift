import SwiftUI

/// Title card overlay for AVPlayerViewController's `contentOverlayView`.
/// Shows the current track's artist and title briefly when a new track starts,
/// then auto-hides after 8 seconds.
///
/// This view reads from `appState` directly (not via @Environment) because it's
/// hosted in a UIHostingController inside contentOverlayView, which is outside
/// the SwiftUI environment chain. It observes appState.currentItem to react
/// to track changes automatically without rootView replacement.
struct TVTitleCardView: View {
    let appState: AppState
    let engine: PlaybackEngine

    @State private var isVisible = false
    @State private var hideTask: Task<Void, Never>?
    @State private var displayedItem: VideoItem?
    @State private var lastShownURL: URL?
    @State private var lastSeenToken: Int = 0

    private var item: VideoItem? {
        engine.playingOpeningBumper ? nil : appState.currentItem
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear

            if isVisible, let displayed = displayedItem, !displayed.isBumper {
                TVTitleCardContent(fileName: displayed.fileName)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: isVisible)
        .allowsHitTesting(false)
        .onChange(of: item?.url) {
            // If the playlist was rebuilt by a genre/settings change, skip.
            if appState.playlistRebuildToken != lastSeenToken {
                lastSeenToken = appState.playlistRebuildToken
                lastShownURL = item?.url
                return
            }
            guard item?.url != lastShownURL else { return }
            showCard()
        }
        .onAppear {
            lastSeenToken = appState.playlistRebuildToken
            if item != nil {
                showCard()
            }
        }
        .onDisappear {
            hideTask?.cancel()
        }
    }

    private func showCard() {
        guard appState.settings.showTitleCards else {
            hideTask?.cancel()
            isVisible = false
            lastShownURL = item?.url
            return
        }
        hideTask?.cancel()
        displayedItem = item
        lastShownURL = item?.url
        isVisible = true
        hideTask = Task {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled {
                isVisible = false
            }
        }
    }
}

// MARK: - Title Card Content

private struct TVTitleCardContent: View {
    let fileName: String

    private var artist: String? { TitleCleaner.parse(fileName).artist }
    private var title: String { TitleCleaner.parse(fileName).title }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let artist {
                Text(artist.uppercased())
                    .font(.system(size: 24, weight: .bold, design: .default))
                    .tracking(2)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 4, x: 0, y: 1)
            }
            Text(title)
                .font(.system(size: 32, weight: .heavy, design: .default))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.7), radius: 4, x: 0, y: 1)
                .lineLimit(2)
        }
        .padding(32)
        .padding(.bottom, 200)  // Clear the transport bar
    }
}
