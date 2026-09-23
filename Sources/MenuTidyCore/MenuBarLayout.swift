/// Geometry used by the native status-item implementation, in screen points.
public enum MenuBarLayout {
    public static let expandedLength: Double = 20
    public static let controlWidth: Double = 28
    private static let minimumCollapsedLength: Double = 32
    private static let layoutMargin: Double = 4

    /// Computes a spacer width without depending on AppKit or screen objects.
    ///
    /// On modern menu bars, an oversized status item may itself disappear. Use
    /// the available right-hand region, leaving room for the control, the other
    /// expanded boundary, and a four-point margin. The 32-point spacer minimum is
    /// retained: regions narrower than 80 points cannot fit all three items, and
    /// regions from 80 to 84 points fit the items with less than the full margin.
    /// Older menu bars allow a spacer wider than the display to move the hidden
    /// group out of view. Pass the widest display's width for that behavior.
    public static func collapsedLength(
        screenWidth: Double,
        rightAreaWidth: Double?,
        applicationMenuWidth: Double = 300,
        modernMenuBar: Bool
    ) -> Double {
        let validScreenWidth = positiveFinite(screenWidth) ?? 1_440
        let maximumLength: Double = 10_000

        guard modernMenuBar else {
            // Bound before multiplying so extreme inputs cannot overflow.
            return max(500, min(validScreenWidth, maximumLength / 2) * 2)
        }

        let menuWidth = applicationMenuWidth.isFinite
            ? max(0, applicationMenuWidth)
            : 300
        let usableWidth = rightAreaWidth.flatMap(positiveFinite)
            ?? max(0, validScreenWidth - menuWidth)
        let reservedWidth = controlWidth + expandedLength + layoutMargin
        return max(minimumCollapsedLength, min(usableWidth - reservedWidth, maximumLength))
    }

    private static func positiveFinite(_ value: Double) -> Double? {
        value.isFinite && value > 0 ? value : nil
    }
}
