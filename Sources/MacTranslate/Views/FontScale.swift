import Foundation
import Observation

/// Popup text zoom (⌘+ / ⌘- / ⌘0), remembered between popups.
@MainActor @Observable
final class FontScale {
    static let shared = FontScale()
    private static let key = "fontScale"
    static let range: ClosedRange<Double> = 0.7...2.0

    var value: Double {
        didSet { UserDefaults.standard.set(value, forKey: Self.key) }
    }

    private init() {
        let v = UserDefaults.standard.double(forKey: Self.key)
        value = v == 0 ? 1.0 : min(max(v, Self.range.lowerBound), Self.range.upperBound)
    }

    func bigger() { value = min(Self.range.upperBound, (value + 0.1).rounded(toPlaces: 1)) }
    func smaller() { value = max(Self.range.lowerBound, (value - 0.1).rounded(toPlaces: 1)) }
    func reset() { value = 1.0 }
}

/// Scaled font size for popup views (reading it inside `body` makes views update on zoom).
@MainActor func fs(_ size: CGFloat) -> CGFloat { size * FontScale.shared.value }

private extension Double {
    func rounded(toPlaces p: Int) -> Double {
        let m = pow(10, Double(p))
        return (self * m).rounded() / m
    }
}
