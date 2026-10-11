import SwiftUI

/// A disclosure whose whole title is clickable. SwiftUI's `DisclosureGroup` on macOS only opens from its
/// small triangle, so clicking the words "Show details" did nothing (first real run). Use this everywhere.
struct Disclosure<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    init(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self._isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded { content() }
        }
    }
}

/// A `Disclosure` that keeps its own open/closed state.
struct LocalDisclosure<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @State private var open = false

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View { Disclosure(title, isExpanded: $open, content: content) }
}
