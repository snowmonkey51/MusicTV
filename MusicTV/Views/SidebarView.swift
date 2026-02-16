import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackEngine.self) private var engine

    var body: some View {
        @Bindable var state = appState

        List {
            Section("Folders") {
                FolderPickerRow(
                    label: "Music Videos",
                    icon: "music.note.tv",
                    selectedURL: appState.musicFolderURL
                ) { url in
                    appState.musicFolderURL = url
                    appState.scanFolder(url: url, isBumper: false)
                }

                FolderPickerRow(
                    label: "Bumpers",
                    icon: "film.stack",
                    selectedURL: appState.bumperFolderURL
                ) { url in
                    appState.bumperFolderURL = url
                    appState.scanFolder(url: url, isBumper: true)
                }
            }

            Section {
                Button(action: { appState.showPlaylist = true }) {
                    HStack {
                        Label("Playlist", systemImage: "list.bullet")
                        Spacer()
                        Text("\(appState.playlist.count)")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                }
                .popover(isPresented: $state.showPlaylist, arrowEdge: .trailing) {
                    PlaylistPopover()
                }
            }

            Section("Playback") {
                Stepper(
                    "Bumper every \(appState.settings.bumperInterval) videos",
                    value: $state.settings.bumperInterval,
                    in: 1...50
                )
                Toggle("Shuffle Music", isOn: $state.settings.shuffleMusic)
                Toggle("Shuffle Bumpers", isOn: $state.settings.shuffleBumpers)
                Toggle("Repeat", isOn: $state.settings.repeatPlaylist)
                Toggle("Normalize Audio", isOn: $state.settings.normalizeAudio)
                    .onChange(of: appState.settings.normalizeAudio) {
                        engine.changeAudioNormalization(appState.settings.normalizeAudio)
                    }
            }

            Section("Appearance") {
                Picker("Video Filter", selection: Binding(
                    get: { appState.currentFilter },
                    set: { newFilter in
                        appState.currentFilter = newFilter
                        appState.saveFilter()
                        engine.changeFilter(newFilter)
                    }
                )) {
                    ForEach(VideoFilter.allCases) { filter in
                        Label(filter.displayName, systemImage: filter.systemImage)
                            .tag(filter)
                    }
                }

                // Logo overlay
                HStack {
                    Label("Logo", systemImage: "photo")
                    Spacer()
                    if appState.logoImage != nil {
                        Button(role: .destructive, action: { appState.removeLogo() }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Button(appState.logoImage != nil ? "Change..." : "Choose...") { pickLogo() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }

                // Opening bumper
                HStack {
                    Label("Intro", systemImage: "film")
                    Spacer()
                    if appState.openingBumperURL != nil {
                        Button(role: .destructive, action: { appState.removeOpeningBumper() }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Button(appState.openingBumperURL != nil ? "Change..." : "Choose...") { pickOpeningBumper() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 250)
    }

    private func pickOpeningBumper() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .avi]
        panel.message = "Select an opening bumper video"
        if panel.runModal() == .OK, let url = panel.url {
            appState.setOpeningBumper(url: url)
        }
    }

    private func pickLogo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.message = "Select a logo image (PNG recommended)"
        if panel.runModal() == .OK, let url = panel.url {
            appState.setLogo(url: url)
        }
    }
}

// MARK: - Playlist Popover

struct PlaylistPopover: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Playlist")
                    .font(.headline)
                Spacer()
                Text("\(appState.playlist.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider()

            if appState.playlist.isEmpty {
                Text("No videos loaded")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(appState.playlist.enumerated()), id: \.element.id) { index, item in
                            PlaylistRow(item: item, isCurrentlyPlaying: index == appState.currentIndex && appState.hasStarted)
                                .id(index)
                        }
                    }
                    .listStyle(.plain)
                    .onAppear {
                        if appState.hasStarted {
                            proxy.scrollTo(appState.currentIndex, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 350, height: 400)
    }
}

// MARK: - Folder Picker Row

struct FolderPickerRow: View {
    let label: String
    let icon: String
    let selectedURL: URL?
    let onSelect: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(label, systemImage: icon)
                Spacer()
                Button("Choose...") { pickFolder() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            if let url = selectedURL {
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select your \(label) folder"
        if panel.runModal() == .OK, let url = panel.url {
            onSelect(url)
        }
    }
}

// MARK: - Playlist Row

struct PlaylistRow: View {
    let item: VideoItem
    let isCurrentlyPlaying: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.isBumper ? "film" : "music.note")
                .foregroundStyle(item.isBumper ? .orange : .primary)
                .frame(width: 20)

            Text(item.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(item.isBumper ? .secondary : .primary)

            Spacer()

            if isCurrentlyPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.tint)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
        .background(isCurrentlyPlaying ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(4)
    }
}
