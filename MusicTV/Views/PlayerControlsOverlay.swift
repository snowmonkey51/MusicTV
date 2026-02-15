import SwiftUI

struct PlayerControlsOverlay: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackEngine.self) private var engine

    @State private var isVisible: Bool = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        @Bindable var engine = engine

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
                    VStack(spacing: 10) {
                        if let item = appState.currentItem {
                            HStack {
                                Image(systemName: item.isBumper ? "film" : "music.note")
                                    .foregroundStyle(item.isBumper ? .orange : .primary)
                                Text(item.fileName)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            .shadow(radius: 2)
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
                        HStack(spacing: 24) {
                            Button(action: { engine.skipBack() }) {
                                Image(systemName: "backward.fill")
                                    .font(.title2)
                            }
                            .buttonStyle(.plain)

                            Button(action: { engine.togglePlayPause() }) {
                                Image(systemName: appState.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title)
                            }
                            .buttonStyle(.plain)

                            Button(action: { engine.skip() }) {
                                Image(systemName: "forward.fill")
                                    .font(.title2)
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            Button(action: { appState.toggleFullScreen() }) {
                                Image(systemName: appState.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                    .font(.title2)
                            }
                            .buttonStyle(.plain)

                            HStack(spacing: 6) {
                                Image(systemName: volumeIcon)
                                    .frame(width: 20)
                                Slider(value: $engine.volume, in: 0...1)
                                    .frame(width: 100)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    .padding(20)
                    .background(
                        .regularMaterial,
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                    .frame(width: 500)
                    Spacer()
                }
                .padding(16)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isVisible)
        .onDisappear { hideTask?.cancel() }
    }

    private var volumeIcon: String {
        if engine.volume == 0 { return "speaker.slash.fill" }
        if engine.volume < 0.33 { return "speaker.fill" }
        if engine.volume < 0.66 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    private func showControls() {
        isVisible = true
        scheduleHide()
    }

    private func toggleVisibility() {
        isVisible.toggle()
        if isVisible { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled {
                isVisible = false
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let mins = total / 60
        let secs = total % 60
        return "\(mins):\(String(format: "%02d", secs))"
    }
}
