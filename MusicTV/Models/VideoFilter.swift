import CoreImage

/// Available video filter presets.
/// Each case builds one or more CIFilters to apply via AVVideoComposition.
enum VideoFilter: String, CaseIterable, Identifiable {
    case none
    case crt
    case blackAndWhite
    case vintage

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:          return "None"
        case .crt:           return "CRT"
        case .blackAndWhite: return "Black & White"
        case .vintage:       return "Vintage"
        }
    }

    var systemImage: String {
        switch self {
        case .none:          return "tv"
        case .crt:           return "tv.and.mediabox"
        case .blackAndWhite: return "circle.lefthalf.filled"
        case .vintage:       return "camera.filters"
        }
    }

    /// Whether this filter requires a custom time-based kernel (not a simple CIFilter chain).
    var usesCustomKernel: Bool {
        switch self {
        case .crt: return true
        default: return false
        }
    }

    /// Builds the chain of CIFilters to apply to each video frame.
    /// Returns an empty array for `.none`.
    func buildFilterChain() -> [CIFilter] {
        switch self {
        case .none:
            return []

        case .crt:
            // Handled by custom composition in PlaybackEngine
            return []

        case .blackAndWhite:
            if let mono = CIFilter(name: "CIPhotoEffectMono") {
                return [mono]
            }
            return []

        case .vintage:
            // Faded colours + warm tint + vignette for an old-film look
            var filters: [CIFilter] = []
            if let fade = CIFilter(name: "CIPhotoEffectFade") {
                filters.append(fade)
            }
            if let color = CIFilter(name: "CIColorControls") {
                color.setValue(0.9, forKey: kCIInputSaturationKey)
                color.setValue(0.03, forKey: kCIInputBrightnessKey)
                filters.append(color)
            }
            if let vignette = CIFilter(name: "CIVignette") {
                vignette.setValue(1.5, forKey: kCIInputRadiusKey)
                vignette.setValue(0.6, forKey: kCIInputIntensityKey)
                filters.append(vignette)
            }
            return filters
        }
    }
}
