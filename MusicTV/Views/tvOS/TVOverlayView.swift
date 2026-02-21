import SwiftUI

/// The tabbed overlay shown when the user swipes up on the Siri Remote.
/// Presented via AVPlayerViewController's `customOverlayViewController`.
///
/// Uses a manual tab bar instead of SwiftUI TabView to avoid a known tvOS
/// focus restoration bug where TabView's internal focus state corrupts
/// after the overlay is dismissed and re-presented via customOverlayViewController.
///
/// Tab content uses native tvOS controls (List, Form, Toggle, Picker) which
/// fill the available vertical space and handle scrolling/focus properly.
struct TVOverlayView: View {
    let appState: AppState
    let engine: PlaybackEngine

    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Manual tab bar
            HStack(spacing: 32) {
                OverlayTabButton(title: "Now Playing", icon: "play.tv",
                                 isSelected: selectedTab == 0) { selectedTab = 0 }
                OverlayTabButton(title: "Libraries", icon: "network",
                                 isSelected: selectedTab == 1) { selectedTab = 1 }
                OverlayTabButton(title: "Playlist", icon: "music.note.list",
                                 isSelected: selectedTab == 2) { selectedTab = 2 }
                OverlayTabButton(title: "Settings", icon: "gearshape",
                                 isSelected: selectedTab == 3) { selectedTab = 3 }
            }
            .padding(.top, 16)
            .padding(.bottom, 8)

            // Content area — each tab is its own independent view with its
            // own scroll state, so scrolling in one tab doesn't affect others.
            switch selectedTab {
            case 0: OverlayNowPlayingTab(appState: appState, engine: engine)
            case 1: OverlayLibrariesTab(appState: appState, engine: engine)
            case 2: OverlayPlaylistTab(appState: appState)
            case 3: OverlaySettingsTab(appState: appState, engine: engine)
            default: EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Tab Button

private struct OverlayTabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
        }
        .opacity(isSelected ? 1 : 0.5)
    }
}

// MARK: - Now Playing Tab

private struct OverlayNowPlayingTab: View {
    let appState: AppState
    let engine: PlaybackEngine

    var body: some View {
        if let item = appState.currentItem {
            let parsed = TitleCleaner.parse(item.fileName)

            List {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            if let artist = parsed.artist {
                                Text(artist)
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                            }
                            Text(parsed.title)
                                .font(.title3)
                                .fontWeight(.semibold)
                        }
                        Spacer()
                        if !item.genres.isEmpty {
                            Text(item.genres.prefix(3).joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    let musicCount = appState.playlist.filter { !$0.isBumper }.count
                    let currentPos = appState.playlist.prefix(appState.currentIndex + 1)
                        .filter { !$0.isBumper }.count
                    Text("Track \(currentPos) of \(musicCount)")
                }

                Section {
                    HStack(spacing: 24) {
                        Button(action: { engine.skipBack() }) {
                            Label("Previous", systemImage: "backward.fill")
                        }

                        Button(action: { engine.skip() }) {
                            Label("Skip", systemImage: "forward.fill")
                        }

                        let isFav = appState.currentItem.map { appState.isFavorite($0) } ?? false
                        Button(action: {
                            if let item = appState.currentItem {
                                appState.toggleFavorite(item)
                            }
                        }) {
                            Label(isFav ? "Unfavorite" : "Favorite",
                                  systemImage: isFav ? "star.fill" : "star")
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "No Track Playing",
                systemImage: "play.tv",
                description: Text("Connect to a library and start playback.")
            )
        }
    }
}

// MARK: - Libraries Tab

private struct OverlayLibrariesTab: View {
    let appState: AppState
    let engine: PlaybackEngine

    var body: some View {
        if appState.libraryBrowser.discoveredLibraries.isEmpty {
            ContentUnavailableView(
                "Searching for Libraries",
                systemImage: "network",
                description: Text("Looking for MusicTV libraries on your network.")
            )
        } else {
            List(appState.libraryBrowser.discoveredLibraries) { library in
                Button(action: { toggleConnection(library) }) {
                    HStack {
                        Image(systemName: "tv.and.hifispeaker.fill")
                        Text(library.name)
                        Spacer()
                        if appState.connectedNetworkLibrary?.id == library.id {
                            if appState.isLoadingNetworkLibrary {
                                ProgressView()
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }
            }
        }
    }

    private func toggleConnection(_ library: DiscoveredLibrary) {
        if appState.connectedNetworkLibrary?.id == library.id {
            appState.disconnectFromNetworkLibrary()
        } else {
            appState.connectToNetworkLibrary(library)
            Task {
                while appState.isLoadingNetworkLibrary {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                if !appState.playlist.isEmpty && !appState.hasStarted {
                    appState.hasStarted = true
                    appState.currentIndex = 0
                    engine.startPlayback()
                }
            }
        }
    }
}

// MARK: - Playlist Tab (Genre Picker)

private struct OverlayPlaylistTab: View {
    let appState: AppState

    var body: some View {
        if appState.musicVideos.isEmpty {
            ContentUnavailableView(
                "No Library Connected",
                systemImage: "music.note.list",
                description: Text("Connect to a MusicTV library to browse playlists.")
            )
        } else {
            List {
                Section {
                    ForEach(appState.availableGenres, id: \.self) { genre in
                        Button(action: { appState.setGenre(genre) }) {
                            HStack {
                                Text(genre)
                                Spacer()
                                if appState.selectedGenre == genre {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                } header: {
                    Text("\(filteredCount) videos in playlist")
                }
            }
        }
    }

    private var filteredCount: Int {
        switch appState.selectedGenre {
        case "All": return appState.musicVideos.count
        case "New": return min(50, appState.musicVideos.count)
        case "Favorites": return appState.favoriteVideos.count
        default: return appState.musicVideos.filter { $0.genres.contains(appState.selectedGenre) }.count
        }
    }
}

// MARK: - Settings Tab

private struct OverlaySettingsTab: View {
    let appState: AppState
    let engine: PlaybackEngine

    var body: some View {
        Form {
            Section("Playback") {
                Toggle("Shuffle Music", isOn: Binding(
                    get: { appState.settings.shuffleMusic },
                    set: { appState.settings.shuffleMusic = $0 }
                ))
                Toggle("Shuffle Bumpers", isOn: Binding(
                    get: { appState.settings.shuffleBumpers },
                    set: { appState.settings.shuffleBumpers = $0 }
                ))
                Toggle("Repeat", isOn: Binding(
                    get: { appState.settings.repeatPlaylist },
                    set: { appState.settings.repeatPlaylist = $0 }
                ))
                Toggle("Normalize Audio", isOn: Binding(
                    get: { appState.settings.normalizeAudio },
                    set: { newValue in
                        appState.settings.normalizeAudio = newValue
                        engine.changeAudioNormalization(newValue)
                    }
                ))
            }

            Section("Bumper Interval") {
                Button(action: {
                    let next = appState.settings.bumperInterval >= 20 ? 1 : appState.settings.bumperInterval + 1
                    appState.settings.bumperInterval = next
                }) {
                    HStack {
                        Text("Play bumper every")
                        Spacer()
                        Text("\(appState.settings.bumperInterval) videos")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Video Filter") {
                // Inline selection — each filter is a button row with a checkmark
                ForEach(VideoFilter.allCases) { filter in
                    Button(action: {
                        appState.currentFilter = filter
                        appState.saveFilter()
                        engine.changeFilter(filter)
                    }) {
                        HStack {
                            Label(filter.displayName, systemImage: filter.systemImage)
                            Spacer()
                            if appState.currentFilter == filter {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }

            Section("Library") {
                if let library = appState.connectedNetworkLibrary {
                    LabeledContent("Server", value: library.name)
                    LabeledContent("Music Videos", value: "\(appState.musicVideos.count)")
                    LabeledContent("Bumpers", value: "\(appState.bumperVideos.count)")
                    Button("Disconnect", role: .destructive) {
                        appState.disconnectFromNetworkLibrary()
                    }
                } else {
                    Text("No library connected")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
