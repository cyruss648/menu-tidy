import SwiftUI

/// Fast operations finish without flashing a loading state. The task belongs to
/// the view, so a new operation or a dismissed window cancels the old delay.
struct DeferredActivity<Content: View>: View {
    var isActive: Bool
    @ViewBuilder var content: (Bool) -> Content
    @State private var delayElapsed = false

    var body: some View {
        content(isActive && delayElapsed)
            .task(id: isActive) {
                delayElapsed = false
                guard isActive else { return }
                do {
                    try await Task.sleep(for: .milliseconds(350))
                    try Task.checkCancellation()
                    delayElapsed = true
                } catch {
                    // Cancellation must never reveal an obsolete spinner.
                }
            }
    }
}

/// The slot stays in the layout; an inactive spinner is neither drawn nor
/// exposed to accessibility.
struct ActivityIndicator: View {
    var isVisible: Bool
    var label: String

    var body: some View {
        Color.clear
            .frame(width: 16, height: 16)
            .overlay {
                if isVisible {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(label)
                }
            }
    }
}
