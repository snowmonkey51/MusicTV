import SwiftUI

// MARK: - Stateful wrapper that manages the show/hide animation

struct TitleCardContainer: View {
    let item: VideoItem?

    @State private var isVisible = false
    @State private var hideTask: Task<Void, Never>?
    @State private var displayedItem: VideoItem?

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
        .onChange(of: item?.id) {
            showCard()
        }
        .onAppear {
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

    private var parsed: (artist: String?, title: String) {
        let cleaned = TitleCleaner.clean(fileName)

        // Check for quoted song title: Artist "Song Title"
        let quotePatterns: [(open: Character, close: Character)] = [
            ("\"", "\""),
            ("\u{201C}", "\u{201D}"),  // "" curly doubles
        ]
        for (open, close) in quotePatterns {
            if let openIdx = cleaned.firstIndex(of: open),
               let closeIdx = cleaned.lastIndex(of: close),
               openIdx < closeIdx {
                let song = String(cleaned[cleaned.index(after: openIdx)..<closeIdx])
                    .trimmingCharacters(in: .whitespaces)
                let artistPart = String(cleaned[cleaned.startIndex..<openIdx])
                    .trimmingCharacters(in: .whitespaces)
                if !song.isEmpty {
                    return (artistPart.isEmpty ? nil : artistPart, song)
                }
            }
        }

        // Fall back to dash separators: Artist - Song Title
        let separators = [" - ", " – ", " — ", " | ", "- "]
        for sep in separators {
            if let range = cleaned.range(of: sep) {
                let artistPart = String(cleaned[cleaned.startIndex..<range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let titlePart = String(cleaned[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                let artist = artistPart.isEmpty ? nil : artistPart
                let title = titlePart.isEmpty ? cleaned : TitleCleaner.stripQuotes(titlePart)
                return (artist, title)
            }
        }

        return (nil, TitleCleaner.stripQuotes(cleaned))
    }

    private var artist: String? { parsed.artist }
    private var title: String { parsed.title }

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
