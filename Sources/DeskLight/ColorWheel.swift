import LampKit
import SwiftUI

/// Hue/saturation wheel drawn inline (the system colour panel would close the menu bar popover).
struct ColorWheel: View {
    let color: RGB
    let onPick: (RGB) -> Void

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2
            let (h, s, _) = color.hsv
            ZStack {
                Circle().fill(AngularGradient(
                    colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { Color(hue: $0, saturation: 1, brightness: 1) },
                    center: .center))
                Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center,
                                             startRadius: 0, endRadius: radius))
                Circle()
                    .strokeBorder(.white, lineWidth: 2)
                    .background(Circle().fill(Color(red: Double(color.r) / 255, green: Double(color.g) / 255,
                                                    blue: Double(color.b) / 255)))
                    .shadow(radius: 1.5)
                    .frame(width: 16, height: 16)
                    .position(x: radius + cos(h * 2 * .pi) * s * radius, y: radius + sin(h * 2 * .pi) * s * radius)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let dx = v.location.x - radius, dy = v.location.y - radius
                // AngularGradient runs clockwise from 3 o'clock, same as atan2 in flipped y.
                var hue = atan2(dy, dx) / (2 * .pi)
                if hue < 0 { hue += 1 }
                let sat = min(1, hypot(dx, dy) / radius)
                onPick(RGB(hue: hue, saturation: sat, value: 1))
            })
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
