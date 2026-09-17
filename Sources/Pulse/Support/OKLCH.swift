import SwiftUI

/// The design spec (Claude Design handoff) defines every accent, status, and
/// per-app color as CSS `oklch(L C H)`. Converting the exact triples instead of
/// eyeballing hex equivalents keeps every color numerically faithful to the source.
/// Formula: https://bottosson.github.io/posts/oklab/
extension Color {
    init(oklch l: Double, _ c: Double, _ h: Double, opacity: Double = 1) {
        let hRad = h * .pi / 180
        let a = c * cos(hRad)
        let b = c * sin(hRad)

        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b

        let l3 = l_ * l_ * l_
        let m3 = m_ * m_ * m_
        let s3 = s_ * s_ * s_

        let r = 4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3
        let g = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3
        let bl = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3

        func toSRGB(_ x: Double) -> Double {
            let v = max(0, min(1, x))
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }

        self = Color(.sRGB, red: toSRGB(r), green: toSRGB(g), blue: toSRGB(bl), opacity: opacity)
    }
}
