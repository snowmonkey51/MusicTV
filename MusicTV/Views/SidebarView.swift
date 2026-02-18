import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackEngine.self) private var engine

    @State private var searchText: String = ""
    @State private var showSearchResults: Bool = false
    @State private var committedSearch: String = ""
    @State private var showFavorites: Bool = false

    var body: some View {
        @Bindable var state = appState

        List {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search videos...", text: $searchText)
                        .textFieldStyle(.plain)
                        .onSubmit {
                            guard !searchText.isEmpty else { return }
                            committedSearch = searchText
                            showSearchResults = true
                        }
                    if !searchText.isEmpty {
                        Button(action: {
                            searchText = ""
                            committedSearch = ""
                            showSearchResults = false
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .popover(isPresented: $showSearchResults, arrowEdge: .trailing) {
                SearchResultsPopover(
                    searchText: committedSearch,
                    onDismiss: {
                        searchText = ""
                        committedSearch = ""
                        showSearchResults = false
                    }
                )
            }

            // Show active filter banner when playing a subset
            if appState.filteredMusicVideos != nil {
                Section {
                    HStack {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                            .foregroundStyle(.tint)
                        Text("Filtered Playlist")
                            .font(.caption)
                        Spacer()
                        Button("Show All") {
                            appState.clearFilter()
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                    }
                }
            }

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

            // Genre filter (only show if genres exist)
            if appState.availableGenres.count > 1 {
                Section {
                    Picker("Genre", selection: Binding(
                        get: { appState.selectedGenre },
                        set: { newGenre in
                            appState.setGenre(newGenre)
                        }
                    )) {
                        ForEach(appState.availableGenres, id: \.self) { genre in
                            Text(genre).tag(genre)
                        }
                    }
                }
            }

            Section {
                Button(action: { appState.showPlaylist = true }) {
                    HStack {
                        Label("Playlist", systemImage: "list.bullet")
                        Spacer()
                        Text("\(appState.playlist.filter { !$0.isBumper }.count)")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                }
                .popover(isPresented: $state.showPlaylist, arrowEdge: .trailing) {
                    PlaylistPopover()
                }

                if !appState.favoritePaths.isEmpty {
                    Button(action: { showFavorites = true }) {
                        HStack {
                            Label("Favorites", systemImage: "star")
                            Spacer()
                            Text("\(appState.favoriteVideos.count)")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                        }
                    }
                    .popover(isPresented: $showFavorites, arrowEdge: .trailing) {
                        FavoritesPopover()
                    }
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
        .safeAreaInset(edge: .bottom) {
            Text("I want my MusicTV")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 12)
        }
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
                Text("\(appState.playlist.filter { !$0.isBumper }.count) videos")
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

// MARK: - Favorites Popover

private struct FavoriteEntry: Identifiable {
    let id: UUID
    let item: VideoItem
    let artist: String
    let title: String
}

struct FavoritesPopover: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackEngine.self) private var engine

    @State private var groups: [(artist: String, entries: [FavoriteEntry])] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Favorites")
                    .font(.headline)
                Spacer()
                Text("\(appState.favoriteVideos.count) videos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider()

            if groups.isEmpty {
                Text("No favorites yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                List {
                    ForEach(groups, id: \.artist) { group in
                        Section {
                            ForEach(group.entries) { entry in
                                HStack(spacing: 8) {
                                    Button(action: { playVideo(entry.item) }) {
                                        HStack(spacing: 8) {
                                            Image(systemName: "music.note")
                                                .foregroundStyle(.primary)
                                                .frame(width: 16)
                                            Text(entry.title)
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                        }
                                    }
                                    .buttonStyle(.plain)

                                    Spacer()

                                    Button(action: {
                                        appState.toggleFavorite(entry.item)
                                        rebuildGroups()
                                    }) {
                                        Image(systemName: "star.slash")
                                            .foregroundStyle(.secondary)
                                            .font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } header: {
                            HStack {
                                Text(group.artist.uppercased())
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .tracking(1)
                                Spacer()
                                if group.entries.count > 1 {
                                    Button(action: {
                                        playAllByArtist(group.entries.map(\.item))
                                    }) {
                                        Label("Play All", systemImage: "play.fill")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 350, height: 400)
        .onAppear { rebuildGroups() }
    }

    private func rebuildGroups() {
        var groupMap: [String: [FavoriteEntry]] = [:]
        for item in appState.favoriteVideos {
            let parsed = TitleCleaner.parse(item.fileName)
            let artistStr = parsed.artist ?? ""
            let entry = FavoriteEntry(
                id: item.id,
                item: item,
                artist: artistStr.isEmpty ? "Unknown" : artistStr,
                title: parsed.title
            )
            groupMap[entry.artist, default: []].append(entry)
        }
        groups = groupMap.map { (artist: $0.key, entries: $0.value) }
            .sorted { $0.artist.localizedStandardCompare($1.artist) == .orderedAscending }
    }

    private func playVideo(_ item: VideoItem) {
        if appState.filteredMusicVideos != nil {
            appState.clearFilter()
        }
        if let index = appState.playlist.firstIndex(where: { $0.url == item.url }) {
            appState.currentIndex = index
            appState.hasStarted = true
            engine.playItem(item)
        }
    }

    private func playAllByArtist(_ items: [VideoItem]) {
        appState.playFilteredVideos(items)
        if let first = appState.playlist.first(where: { !$0.isBumper }) {
            engine.playItem(first)
        }
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

// MARK: - Search Results Popover

/// Pre-parsed search entry to avoid re-parsing on every render.
private struct SearchEntry: Identifiable {
    let id: UUID
    let item: VideoItem
    let artist: String
    let title: String
}

struct SearchResultsPopover: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackEngine.self) private var engine

    let searchText: String
    let onDismiss: () -> Void

    @State private var results: [(artist: String, entries: [SearchEntry])] = []
    @State private var totalCount: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Results")
                    .font(.headline)
                Spacer()
                Text("\(totalCount) found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider()

            if results.isEmpty {
                Text("No matching videos")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                List {
                    ForEach(results, id: \.artist) { group in
                        Section {
                            ForEach(group.entries) { entry in
                                Button(action: { playVideo(entry.item) }) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "music.note")
                                            .foregroundStyle(.primary)
                                            .frame(width: 16)
                                        Text(entry.title)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            HStack {
                                Text(group.artist.uppercased())
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .tracking(1)
                                Spacer()
                                if group.entries.count > 1 {
                                    Button(action: {
                                        playAllByArtist(group.entries.map(\.item))
                                    }) {
                                        Label("Play All", systemImage: "play.fill")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 350, height: 400)
        .onAppear { performSearch() }
    }

    private func performSearch() {
        guard !searchText.isEmpty else {
            results = []
            totalCount = 0
            return
        }

        let query = searchText.lowercased()
        var groups: [String: [SearchEntry]] = [:]
        var count = 0

        for item in appState.musicVideos {
            let parsed = TitleCleaner.parse(item.fileName)
            let artistStr = parsed.artist ?? ""
            let titleStr = parsed.title

            let artistMatch = artistStr.lowercased().contains(query)
            let titleMatch = titleStr.lowercased().contains(query)
            let fileMatch = item.fileName.lowercased().contains(query)

            if artistMatch || titleMatch || fileMatch {
                let entry = SearchEntry(
                    id: item.id,
                    item: item,
                    artist: artistStr.isEmpty ? "Unknown" : artistStr,
                    title: titleStr
                )
                groups[entry.artist, default: []].append(entry)
                count += 1
            }
        }

        results = groups.map { (artist: $0.key, entries: $0.value) }
            .sorted { $0.artist.localizedStandardCompare($1.artist) == .orderedAscending }
        totalCount = count
    }

    private func playVideo(_ item: VideoItem) {
        if appState.filteredMusicVideos != nil {
            appState.clearFilter()
        }
        if let index = appState.playlist.firstIndex(where: { $0.url == item.url }) {
            appState.currentIndex = index
            appState.hasStarted = true
            engine.playItem(item)
        }
        onDismiss()
    }

    private func playAllByArtist(_ items: [VideoItem]) {
        appState.playFilteredVideos(items)
        if let first = appState.playlist.first(where: { !$0.isBumper }) {
            engine.playItem(first)
        }
        onDismiss()
    }
}
