import SwiftUI

/// Track info view for AVPlayerViewController's `customInfoViewControllers`.
/// Shown when the user swipes down on the Siri Remote during playback.
///
/// Displays the current track's artist, title, genre tags, favorite status,
/// and playlist position. Reads from appState directly and observes changes
/// automatically without rootView replacement.
struct TVTrackInfoView: View {
    let appState: AppState
    let engine: PlaybackEngine

    private var item: VideoItem? {
        engine.playingOpeningBumper ? nil : appState.currentItem
    }

    var body: some View {
        if let item, !item.isBumper {
            let parsed = TitleCleaner.parse(item.fileName)

            VStack(alignment: .leading, spacing: 16) {
                // Artist
                if let artist = parsed.artist {
                    Text(artist)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                // Title
                Text(parsed.title)
                    .font(.title2)
                    .fontWeight(.bold)

                // Genre tags
                if !item.genres.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(item.genres, id: \.self) { genre in
                            Text(genre)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(Color.secondary.opacity(0.2))
                                )
                        }
                    }
                }

                Divider()

                // Playlist position
                HStack {
                    let musicCount = appState.playlist.filter { !$0.isBumper }.count
                    let currentPos = appState.playlist.prefix(appState.currentIndex + 1)
                        .filter { !$0.isBumper }.count

                    Label("Track \(currentPos) of \(musicCount)", systemImage: "music.note.list")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()

                    // Favorite indicator
                    let isFav = appState.isFavorite(item)
                    Label(
                        isFav ? "Favorited" : "Not Favorited",
                        systemImage: isFav ? "star.fill" : "star"
                    )
                    .font(.subheadline)
                    .foregroundStyle(isFav ? .yellow : .secondary)
                }
            }
            .padding(24)
        } else {
            VStack {
                Text("No track information available")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }
}
