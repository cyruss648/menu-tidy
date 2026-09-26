/// Fits one already-visible status item inside the measured native right area.
/// This plans only geometry; callers must verify actual hiding after applying it.
public enum MenuBarBlockerGeometry {
    /// Leave room at the leading edge for the native overflow entry. Its state
    /// and the target icons still require independent runtime verification.
    public static let leadingReserve: Double = 20

    public static func fittedWidth(frameRight: Double, leftEdge: Double,
                                   requested: Double, actual: Double) -> Double? {
        guard [frameRight, leftEdge, requested, actual].allSatisfy(\.isFinite),
              requested >= MenuBarLayout.expandedLength, actual >= requested else { return nil }
        let region = frameRight - leftEdge
        guard region.isFinite, region > 0 else { return nil }
        let targetActual = region - leadingReserve
        let hostOverhead = actual - requested
        let fittedRequest = targetActual - hostOverhead
        // Do not impose a minimum that exceeds the observed budget, or amplify
        // an ignored request whose rendered width is smaller than requested.
        guard targetActual.isFinite, fittedRequest.isFinite,
              fittedRequest >= MenuBarLayout.expandedLength,
              fittedRequest <= targetActual, targetActual < region,
              // A known host item may straddle the notch after another item
              // is restored. Such geometry authorizes only shrinking this
              // item; enlargement still requires a fully fitting old frame.
              actual <= region || fittedRequest < requested else { return nil }
        return fittedRequest
    }

    /// Reserve exactly one verified item's hosted width. Subtract the physical
    /// width once: the blocker's existing host padding remains unchanged.
    public static func reservedWidth(requested: Double, actual: Double,
                                     targetHostWidth: Double) -> Double? {
        guard [requested, actual, targetHostWidth].allSatisfy(\.isFinite),
              requested >= MenuBarLayout.expandedLength, actual >= requested,
              targetHostWidth > 0, targetHostWidth <= 120 else { return nil }
        let result = requested - targetHostWidth
        guard result > MenuBarLayout.expandedLength else { return nil }
        return result
    }

}
