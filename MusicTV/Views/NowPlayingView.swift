import AppKit
import SwiftUI

struct NowPlayingView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackEngine.self) private var engine

    var body: some View {
        ZStack {
            if appState.playlist.isEmpty {
                ContentUnavailableView(
                    "No Videos Loaded",
                    systemImage: "tv",
                    description: Text("Choose a music videos folder from the sidebar to get started.")
                )
            } else if !appState.hasStarted {
                VStack(spacing: 20) {
                    Image(systemName: "tv")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)

                    Text("Ready to Play")
                        .font(.title)
                        .fontWeight(.medium)

                    Text("\(appState.playlist.count) videos queued")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button(action: {
                        appState.hasStarted = true
                        appState.currentIndex = 0
                        if let item = appState.currentItem {
                            engine.playItem(item)
                        }
                    }) {
                        Label("Play", systemImage: "play.fill")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.glass)
                }
            } else {
                VideoPlayerView(player: engine.player)
                    .aspectRatio(16/9, contentMode: .fit)
                    .onTapGesture(count: 2) {
                        appState.toggleFullScreen()
                    }
                PlayerControlsOverlay()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if appState.isFullScreen {
                Color.black.ignoresSafeArea()
            } else {
                VisualEffectBackground()
                    .ignoresSafeArea()
            }
        }
    }
}

// MARK: - Translucent Window Background

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
