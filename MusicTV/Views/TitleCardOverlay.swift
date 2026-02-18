import SwiftUI

// MARK: - Stateful wrapper that manages the show/hide animation

struct TitleCardContainer: View {
    let item: VideoItem?
    @Environment(AppState.self) private var appState

    @State private var isVisible = false
    @State private var hideTask: Task<Void, Never>?
    @State private var displayedItem: VideoItem?
    @State private var lastShownURL: URL?
    @State private var lastSeenToken: Int = 0

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear

            if isVisible, let item = displayedItem, !item.isBumper {
                TitleCardContent(fileName: item.fileName)
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

// MARK: - The actual text content

private struct TitleCardContent: View {
    let fileName: String

    private var artist: String? { TitleCleaner.parse(fileName).artist }
    private var title: String { TitleCleaner.parse(fileName).title }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let artist {
                Text(artist.uppercased())
                    .font(.system(size: 20, weight: .bold, design: .default))
                    .tracking(2)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 4, x: 0, y: 1)
            }
            Text(title)
                .font(.system(size: 28, weight: .heavy, design: .default))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.7), radius: 4, x: 0, y: 1)
                .lineLimit(2)
        }
        .padding(24)
        .padding(.bottom, 40)
    }
}

// MARK: - Title Cleaner

/// Strips common junk from video filenames for clean display.
/// Add new patterns to `filterPatterns` as needed.
enum TitleCleaner {

    /// Case-insensitive patterns to remove (parenthesized, bracketed, or standalone).
    /// Order doesn't matter — all are applied.
    private static let filterPatterns: [String] = [
        // Video type tags
        "(Official Video)",
        "(Official Music Video)",
        "(Official Audio)",
        "(Official Visualizer)",
        "(Official Lyric Video)",
        "(Official Lyrics Video)",
        "(Official HD Video)",
        "(Official Performance Video)",
        "(Music Video)",
        "(Lyric Video)",
        "(Lyrics Video)",
        "(Lyrics)",
        "(Audio)",
        "(Visualizer)",
        "(Live)",
        "(Acoustic)",
        "(Unplugged)",
        "(Remix)",
        "(Clean)",
        "(Explicit)",
        "(Bonus Track)",

        // Bracketed variants
        "[Official Video]",
        "[Official Music Video]",
        "[Official Audio]",
        "[Music Video]",
        "[Lyric Video]",
        "[Lyrics]",
        "[Audio]",
        "[Live]",
        "[HD]",
        "[HQ]",

        // Resolution & quality tags
        "(4K)",
        "(HD)",
        "(HQ)",
        "(1080p)",
        "(720p)",
        "(4K UHD)",
        "[4K]",
        "[1080p]",
        "[720p]",

        // Platform tags
        "(YouTube)",
        "(Vevo)",
        "[Vevo]",

        // Year patterns are handled separately below
    ]

    static func clean(_ input: String) -> String {
        var result = input

        // Remove all known filter patterns (case-insensitive)
        for pattern in filterPatterns {
            while let range = result.range(of: pattern, options: .caseInsensitive) {
                result.removeSubrange(range)
            }
        }

        // Remove trailing year in parens/brackets like (2024) or [2019]
        result = result.replacingOccurrences(
            of: #"\s*[\(\[]\d{4}[\)\]]\s*$"#,
            with: "",
            options: .regularExpression
        )

        // Remove trailing _1, _2, etc. (duplicate file suffixes)
        result = result.replacingOccurrences(
            of: #"\s*_\d+\s*$"#,
            with: "",
            options: .regularExpression
        )

        // Remove leading track numbers like "01 ", "01. ", "1. "
        result = result.replacingOccurrences(
            of: #"^\d{1,3}[\.\-\)]\s*"#,
            with: "",
            options: .regularExpression
        )

        // Collapse multiple spaces and trim
        result = result.replacingOccurrences(
            of: #"\s{2,}"#,
            with: " ",
            options: .regularExpression
        )

        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Parses a filename into an optional artist and a title.
    /// Checks for quoted song titles first, then falls back to dash/pipe separators.
    /// Extracts (feat. ...) / (ft. ...) from the title and appends to the artist.
    static func parse(_ fileName: String) -> (artist: String?, title: String) {
        let cleaned = clean(fileName)

        var rawArtist: String?
        var rawTitle: String = cleaned

        // Check for quoted song title: Artist "Song Title"
        let quotePatterns: [(open: Character, close: Character)] = [
            ("\"", "\""),
            ("\u{201C}", "\u{201D}"),  // "" curly doubles
        ]
        var matched = false
        for (open, close) in quotePatterns {
            if let openIdx = cleaned.firstIndex(of: open),
               let closeIdx = cleaned.lastIndex(of: close),
               openIdx < closeIdx {
                let song = String(cleaned[cleaned.index(after: openIdx)..<closeIdx])
                    .trimmingCharacters(in: .whitespaces)
                let artistPart = String(cleaned[cleaned.startIndex..<openIdx])
                    .trimmingCharacters(in: .whitespaces)
                if !song.isEmpty {
                    rawArtist = artistPart.isEmpty ? nil : artistPart
                    rawTitle = song
                    matched = true
                    break
                }
            }
        }

        // Fall back to dash separators: Artist - Song Title
        if !matched {
            let separators = [" - ", " \u{2013} ", " \u{2014} ", " | ", "- "]
            for sep in separators {
                if let range = cleaned.range(of: sep) {
                    let artistPart = String(cleaned[cleaned.startIndex..<range.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                    let titlePart = String(cleaned[range.upperBound...])
                        .trimmingCharacters(in: .whitespaces)
                    rawArtist = artistPart.isEmpty ? nil : artistPart
                    rawTitle = titlePart.isEmpty ? cleaned : stripQuotes(titlePart)
                    break
                }
            }
        }

        if !matched && rawArtist == nil {
            rawTitle = stripQuotes(cleaned)
        }

        // Extract (feat. ...) or (ft. ...) from either the title or leftover text
        let featResult = extractFeatured(from: rawTitle)
        rawTitle = featResult.cleaned

        // Also check the artist part for feat tags (e.g. "Artist (feat. Other) - Song")
        var featArtists = featResult.featured
        if let artist = rawArtist {
            let artistFeatResult = extractFeatured(from: artist)
            if !artistFeatResult.featured.isEmpty {
                rawArtist = artistFeatResult.cleaned
                featArtists.append(contentsOf: artistFeatResult.featured)
            }
        }

        // Combine main artist with featured artists using &
        if !featArtists.isEmpty {
            let featString = featArtists.joined(separator: " & ")
            if let main = rawArtist, !main.isEmpty {
                rawArtist = main + " & " + featString
            } else {
                rawArtist = featString
            }
        }

        return (rawArtist, rawTitle)
    }

    /// Extracts featured artist names from text like "(feat. Artist & Artist)" or "(ft. Artist)".
    /// Returns the cleaned text with the feat tag removed, and an array of featured artist names.
    private static func extractFeatured(from text: String) -> (cleaned: String, featured: [String]) {
        // Match (feat. ...), (ft. ...), [feat. ...], [ft. ...] — case insensitive
        let pattern = #"[\(\[]\s*(?:feat\.?|ft\.?)\s+(.+?)[\)\]]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let featRange = Range(match.range(at: 1), in: text) else {
            return (text, [])
        }

        let featContent = String(text[featRange]).trimmingCharacters(in: .whitespaces)
        let fullMatchRange = Range(match.range, in: text)!
        var cleaned = text
        cleaned.removeSubrange(fullMatchRange)
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)

        // Split featured artists by & or ,
        let artists = featContent
            .components(separatedBy: CharacterSet(charactersIn: "&,"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return (cleaned, artists)
    }

    /// Strips wrapping quotes: "Song Title" → Song Title, 'Song Title' → Song Title
    static func stripQuotes(_ input: String) -> String {
        var s = input
        let quotePairs: [(Character, Character)] = [
            ("\"", "\""),
            ("\u{201C}", "\u{201D}"),  // "" curly double quotes
            ("'", "'"),
            ("\u{2018}", "\u{2019}"),  // '' curly single quotes
        ]
        for (open, close) in quotePairs {
            if s.first == open && s.last == close && s.count > 2 {
                s.removeFirst()
                s.removeLast()
                s = s.trimmingCharacters(in: .whitespaces)
                break
            }
        }
        return s
    }
}
