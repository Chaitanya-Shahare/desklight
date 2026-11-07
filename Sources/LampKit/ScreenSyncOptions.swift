import CoreGraphics

/// Which part of the display Screen sync reads. Rectangles use unit coordinates with the
/// origin at the top-left of the display.
public enum ScreenRegion: String, CaseIterable, Identifiable, Sendable {
    case full = "Full screen"
    /// Thin bands around the border, like a TV backlight. Ignores the middle of the picture.
    case edges = "Edges"
    case bottom = "Bottom"
    /// Lower middle of the picture, where the action is in most films.
    case bottomCenter = "Bottom center"
    case center = "Center"

    public var id: String { rawValue }

    static let edgeFraction = 0.12

    /// Part of the display to capture. Capturing less of the screen costs less.
    public var captureRect: CGRect {
        switch self {
        case .full, .edges: CGRect(x: 0, y: 0, width: 1, height: 1)
        case .bottom: CGRect(x: 0, y: 0.8, width: 1, height: 0.2)
        case .bottomCenter: CGRect(x: 0.22, y: 0.72, width: 0.56, height: 0.28)
        case .center: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
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

/// How quickly Screen sync follows the picture. Faster profiles capture more often and use
/// more battery.
public enum ScreenProfile: String, CaseIterable, Identifiable, Sendable {
    /// Slow, steady ambient colour. Lowest battery use.
    case calm = "Calm"
    /// Follows scene changes without flicker.
    case movie = "Movie"
    /// Snappy; reacts to explosions and flashes.
    case game = "Game"

    public var id: String { rawValue }

    /// Screen frames captured per second.
    public var framesPerSecond: Int {
        switch self {
        case .calm: 4
        case .movie: 10
        case .game: 20
        }
    }

    /// How far each new frame pulls the colour (0–1). Lower is calmer.
    public var smoothing: Double {
        switch self {
        case .calm: 0.15
        case .movie: 0.5
        case .game: 0.85
        }
    }

    /// Lamp glide time constant in seconds.
    public var glide: Double {
        switch self {
        case .calm: 0.8
        case .movie: 0.25
        case .game: 0.06
        }
    }

    /// Smallest colour change (sum of R, G, B differences) worth sending to the lamp.
    public var minChange: Int {
        switch self {
        case .calm: 8
        case .movie: 3
        case .game: 2
        }
    }
}
