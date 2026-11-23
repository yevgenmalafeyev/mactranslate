import SwiftUI

private struct GrowPopupKey: EnvironmentKey {
    static let defaultValue: @MainActor (CGFloat) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Asks the popup window to grow by the given number of points (clamped to the screen).
    var growPopup: @MainActor (CGFloat) -> Void {
        get { self[GrowPopupKey.self] }
        set { self[GrowPopupKey.self] = newValue }
    }
}

/// A vertical ScrollView that asks the popup to grow when its content overflows.
struct AutoGrowScrollView<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.growPopup) private var grow
    @State private var contentHeight: CGFloat = 0
    @State private var visibleHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                    contentHeight = h
                    check()
                }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
            visibleHeight = h
            check()
        }
    }

    private func check() {
        guard visibleHeight > 0 else { return }
        let overflow = contentHeight - visibleHeight
        if overflow > 2 { grow(overflow) }
    }
}
