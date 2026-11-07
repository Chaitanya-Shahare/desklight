import CoreGraphics

/// Which part of the display Screen sync reads. Each style picks its own; see `ScreenProfile.region`.
/// Rectangles use unit coordinates with the origin at the top-left of the display.
public enum ScreenRegion: String, CaseIterable, Sendable {
    /// Lower middle of the picture: where the action is in most films, clear of menu bars,
    /// docks and letterbox bars.
    case bottomCenter
    /// Thin bands around the border, like a TV backlight extending the picture onto the wall.
    case edges

    static let edgeFraction = 0.12

    /// Part of the display to capture. Capturing less of the screen costs less.
    public var captureRect: CGRect {
        switch self {
        case .bottomCenter: CGRect(x: 0.22, y: 0.72, width: 0.56, height: 0.28)
        case .edges: CGRect(x: 0, y: 0, width: 1, height: 1)
        }
    }

    /// Pixels to count within the captured area (unit coordinates of that area); nil means all.
    public var sampleRects: [CGRect]? {
        guard self == .edges else { return nil }
        let e = Self.edgeFraction
        return [
            CGRect(x: 0, y: 0, width: 1, height: e),       // top
            CGRect(x: 0, y: 1 - e, width: 1, height: e),   // bottom
            CGRect(x: 0, y: 0, width: e, height: 1),       // left
            CGRect(x: 1 - e, y: 0, width: e, height: 1),   // right
        ]
    }
}

/// Screen sync styles. Values are the solid/movie/game modes of the Python `ambilight.py`
/// that was tuned on an LEDDMX-03 strip. Faster styles capture more often and use more battery.
public enum ScreenProfile: String, CaseIterable, Identifiable, Sendable {
    /// Slow, steady ambient colour. Lowest battery use.
    case solid = "Solid"
    /// Follows scene changes without flicker.
    case movie = "Movie"
    /// Snappy; reacts to explosions and flashes.
    case game = "Game"

    public var id: String { rawValue }

    public var region: ScreenRegion {
        switch self {
        case .solid, .movie: .bottomCenter
        case .game: .edges
        }
    }

    /// Screen frames captured per second.
    public var framesPerSecond: Int {
        switch self {
        case .solid: 4
        case .movie: 10
        case .game: 20
        }
    }

    /// How far each new frame pulls the colour (0–1). Lower is calmer.
    public var smoothing: Double {
        switch self {
        case .solid: 0.15
        case .movie: 0.5
        case .game: 0.85
        }
    }

    /// Lamp glide time constant in seconds.
    public var glide: Double {
        switch self {
        case .solid: 0.8
        case .movie: 0.25
        case .game: 0.06
        }
    }

    /// How strongly colourful pixels outweigh grey ones (0 = plain average).
    public var satWeight: Double {
        switch self {
        case .solid: 1.0
        case .movie: 1.5
        case .game: 2.0
        }
    }

    /// Saturation multiplier applied to the result.
    public var saturation: Double {
        switch self {
        case .solid: 1.5
        case .movie: 2.0
        case .game: 2.6
        }
    }

    /// Brightness multiplier applied to the result.
    public var gain: Double {
        switch self {
        case .solid: 1.4
        case .movie: 1.7
        case .game: 1.9
        }
    }

    /// Smallest colour change (sum of R, G, B differences) worth sending to the lamp.
    public var minChange: Int {
        switch self {
        case .solid: 8
        case .movie: 3
        case .game: 2
        }
    }
}
