import AppKit
import AVKit
import SwiftUI

// MARK: - Shared Controls Content

/// The actual transport controls, progress bar, and volume — used by both
/// the inline bar (windowed) and the floating overlay (fullscreen).
struct PlayerControlsContent: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackEngine.self) private var engine

    /// When true, renders with glass background and constrained width (fullscreen overlay).
    /// When false, renders flat and full-width (inline bar below video).
    var floating: Bool = false

    @State private var displayedArtist: String?
    @State private var displayedTitle: String?
    @State private var lastSeenToken: Int = 0

    var body: some View {
        @Bindable var engine = engine

        VStack(spacing: 10) {
            if let title = displayedTitle, !engine.playingOpeningBumper {
                Group {
                    if let artist = displayedArtist {
                        Text(artist) + Text(" - ") + Text(title)
                    } else {
                        Text(title)
                    }
                }
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            }

            // Progress bar
            GeometryReader { geo in
                let fraction = engine.duration > 0 ? engine.currentTime / engine.duration : 0
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.secondary.opacity(0.3))
                        .frame(height: 6)
                    Capsule()
                        .fill(.tint)
                        .frame(width: max(0, geo.size.width * fraction), height: 6)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let seekFraction = max(0, min(1, value.location.x / geo.size.width))
                            engine.seek(to: seekFraction)
                        }
                )
            }
            .frame(height: 6)

            // Time labels
            HStack {
                Text(formatTime(engine.currentTime))
                Spacer()
                Text(formatTime(engine.duration))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()

            // Transport controls
            ZStack {
                // Centered transport buttons
                HStack(spacing: 24) {
                    Button(action: { engine.skipBack() }) {
                        Image(systemName: "backward.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)

                    Button(action: { engine.togglePlayPause() }) {
                        Image(systemName: appState.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title)
                            .frame(width: 32, height: 32)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)

                    Button(action: { engine.skip() }) {
                        Image(systemName: "forward.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                }

                // Left-aligned fullscreen, right-aligned favorite + volume
                HStack {
                    Button(action: { appState.toggleFullScreen() }) {
                        Image(systemName: appState.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.title2)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    if let item = appState.currentItem, !item.isBumper {
                        Button(action: { appState.toggleFavorite(item) }) {
                            Image(systemName: appState.isFavorite(item) ? "star.fill" : "star")
                                .font(.title2)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                    }

                    AirPlayRoutePickerButton()
                        .frame(width: 24, height: 24)

                    HStack(spacing: 6) {
                        Image(systemName: volumeIcon)
                            .frame(width: 20)
                        Slider(value: $engine.volume, in: 0...1)
                            .frame(width: 100)
                    }
                }
            }
            .foregroundStyle(.primary)
        }
        .padding(floating ? 20 : 16)
        .animation(nil, value: appState.isPlaying)
        .if(floating) { view in
            view
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
                .frame(width: 600)
        }
        .onChange(of: appState.currentItem?.url) {
            if appState.playlistRebuildToken != lastSeenToken {
                lastSeenToken = appState.playlistRebuildToken
                return
            }
            updateDisplayedName()
        }
        .onAppear {
            lastSeenToken = appState.playlistRebuildToken
            updateDisplayedName()
        }
    }

    private func updateDisplayedName() {
        if let item = appState.currentItem, !item.isBumper {
            let parsed = TitleCleaner.parse(item.fileName)
            displayedArtist = parsed.artist
            displayedTitle = parsed.title
        } else {
            displayedArtist = nil
            displayedTitle = nil
        }
    }

    private var volumeIcon: String {
        if engine.volume == 0 { return "speaker.slash.fill" }
        if engine.volume < 0.33 { return "speaker.fill" }
        if engine.volume < 0.66 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let mins = total / 60
        let secs = total % 60
        return "\(mins):\(String(format: "%02d", secs))"
    }
}

// MARK: - Conditional modifier helper

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: - Inline Controls Bar (windowed mode, below video)

struct PlayerControlsBar: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackEngine.self) private var engine

    var body: some View {
        if appState.hasStarted {
            PlayerControlsContent(floating: false)
        }
    }
}

// MARK: - Floating Controls Overlay (fullscreen mode, auto-hide)

struct PlayerControlsOverlay: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackEngine.self) private var engine

    @State private var isVisible: Bool = true
    @State private var hideTask: Task<Void, Never>?
    @State private var hoveringControls: Bool = false

    var body: some View {
        if engine.playingOpeningBumper {
            Color.clear
        } else {
        ZStack(alignment: .bottom) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleVisibility() }
                .onHover { hovering in
                    if hovering { showControls() }
                }

            if isVisible {
                HStack {
                    Spacer()
                    PlayerControlsContent(floating: true)
                        .onHover { hovering in
                            hoveringControls = hovering
                            if hovering {
                                hideTask?.cancel()
                            } else {
                                scheduleHide()
                            }
                        }
                    Spacer()
                }
                .padding(16)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isVisible)
        .onAppear { scheduleHide() }
        .onDisappear { hideTask?.cancel() }
        }
    }

    private func showControls() {
        isVisible = true
        NSCursor.setHiddenUntilMouseMoves(false)
        scheduleHide()
    }

    private func toggleVisibility() {
        isVisible.toggle()
        if isVisible {
            NSCursor.setHiddenUntilMouseMoves(false)
            scheduleHide()
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled && !hoveringControls {
                isVisible = false
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
    }
}

// MARK: - AirPlay Route Picker

/// Wraps AVRoutePickerView for use in SwiftUI.
struct AirPlayRoutePickerButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        return picker
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
