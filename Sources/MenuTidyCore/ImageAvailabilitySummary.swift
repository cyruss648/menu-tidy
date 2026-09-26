/// Image coverage for a caller-defined set of currently observed items.
/// Preparation errors are deliberately not inputs: an existing valid image can
/// satisfy a request even when no new image was captured during this refresh.
public struct ImageAvailabilitySummary: Equatable, Sendable {
    public let requested: Set<String>
    public let captured: Set<String>
    public let missing: Set<String>

    public init(requested: Set<String>, available: Set<String>) {
        self.requested = requested
        captured = requested.intersection(available)
        missing = requested.subtracting(available)
    }

    public var hasMissingImages: Bool { !missing.isEmpty }

    /// An empty observation is not evidence that every configured item has an
    /// image. The caller can distinguish it from a nonempty complete inventory.
    public var isComplete: Bool { !requested.isEmpty && missing.isEmpty }
}
