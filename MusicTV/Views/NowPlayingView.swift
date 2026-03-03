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
                    if let logo = appState.logoImage {
                        Image(nsImage: logo)
                            .interpolation(.high)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 120)
                    } else {
                        Image(systemName: "tv")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                    }

                    Text("Ready to Play")
                        .font(.title)
                        .fontWeight(.medium)

                    Text("\(appState.playlist.filter { !$0.isBumper }.count) videos queued")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button(action: {
                        appState.hasStarted = true
                        appState.currentIndex = 0
                        engine.startPlayback()
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
                VStack(spacing: 0) {
                    VideoPlayerView(player: engine.player)
                        .aspectRatio(16/9, contentMode: .fit)
                        .overlay(alignment: .bottom) {
                            let isBumper = engine.playingOpeningBumper || (appState.currentItem?.isBumper == true)
                            HStack(alignment: .bottom) {
                                // MTV-style title card in lower-left
                                TitleCardContainer(item: engine.playingOpeningBumper ? nil : appState.currentItem)

                                Spacer()

                                // MTV-style logo bug in lower-right
                                if !isBumper, let logo = appState.logoImage {
                                    Image(nsImage: logo)
                                        .interpolation(.high)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(height: appState.isFullScreen ? 110 : 80)
                                        .opacity(0.7)
                                        .padding(.trailing, 24)
                                        .padding(.bottom, 40)
                                        .allowsHitTesting(false)
                                }
                            }
                        }
                        .overlay {
                            // Floating controls only in fullscreen
                            if appState.isFullScreen {
                                PlayerControlsOverlay()
                            }
                        }
                        .onTapGesture(count: 2) {
                            appState.toggleFullScreen()
                        }
                        .layoutPriority(1)

                    // Inline controls bar below video in windowed mode
                    if !appState.isFullScreen {
                        PlayerControlsBar()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
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
