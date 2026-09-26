/// Removes a confidently uniform menu-bar background from opaque RGBA8 pixels.
/// This is intentionally conservative: uncertain or already-transparent input
/// is returned unchanged, without interpreting its alpha representation.
public enum MenuBarIconMatte {
    public struct Result: Equatable, Sendable {
        public let pixels: [UInt8]
        public let isTemplate: Bool
        public let removedBackground: Bool
    }

    private static let backgroundTolerance = 12
    private static let monochromeResidual = 6.0

    /// Input is tightly packed, eight-bit RGBA. Invalid dimensions or byte
    /// counts return nil. Template output is premultiplied black plus coverage;
    /// colored output preserves foreground pixels and clears the confirmed
    /// uniform background, including enclosed holes, to transparent black.
    public static func process(width: Int, height: Int, pixels: [UInt8]) -> Result? {
        guard width > 0, height > 0 else { return nil }
        let (pixelCount, countOverflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !countOverflow, !byteOverflow, pixels.count == byteCount else { return nil }
        let unchanged = Result(pixels: pixels, isTemplate: false, removedBackground: false)
        guard stride(from: 3, to: byteCount, by: 4).allSatisfy({ pixels[$0] == 255 }) else {
            return unchanged
        }

        let top = Array(0..<width)
        let bottom = Array(((height - 1) * width)..<pixelCount)
        let left = (0..<height).map { $0 * width }
        let right = (0..<height).map { $0 * width + width - 1 }
        // Count each corner once for the overall confidence estimate.
        var border = top
        if height > 1 { border.append(contentsOf: bottom) }
        if height > 2 {
            for row in 1..<(height - 1) {
                border.append(row * width)
                if width > 1 { border.append(row * width + width - 1) }
            }
        }
        let background = (0..<3).map { channel in
            let values = border.map { Int(pixels[$0 * 4 + channel]) }.sorted()
            return values[values.count / 2]
        }
        func isBackground(_ index: Int) -> Bool {
            (0..<3).allSatisfy {
                abs(Int(pixels[index * 4 + $0]) - background[$0]) <= backgroundTolerance
            }
        }
        func support(_ indices: [Int]) -> Double {
            Double(indices.filter(isBackground).count) / Double(indices.count)
        }
        let sideSupport = [top, bottom, left, right].map(support)
        let corners = [0, width - 1, (height - 1) * width, pixelCount - 1]
        // A genuine glyph can touch one crop edge. Require three consistent
        // edges and corners instead of rejecting that entire icon. A differently
        // coloured whole edge (including its corners) remains ambiguous.
        guard support(border) >= 0.65, support(corners) >= 0.75,
              sideSupport.filter({ $0 >= 0.8 }).count >= 3 else { return unchanged }

        let foreground = (0..<pixelCount).filter { !isBackground($0) }
        // A featureless patch cannot establish that an icon was captured.
        guard !foreground.isEmpty else { return unchanged }

        if let endpoint = monochromeEndpoint(pixels: pixels, foreground: foreground, background: background) {
            let denominator = (0..<3).reduce(0.0) {
                let component = Double(endpoint - background[$1])
                return $0 + component * component
            }
            var output = [UInt8](repeating: 0, count: byteCount)
            for index in foreground {
                let alpha = coverage(at: index, pixels: pixels, background: background,
                                     endpoint: endpoint, denominator: denominator)
                output[index * 4 + 3] = UInt8((alpha * 255).rounded())
            }
            // In the proven monochrome case all near-background pixels are
            // transparent, including enclosed letter/icon holes.
            return Result(pixels: output, isTemplate: true, removedBackground: true)
        }

        var output = pixels
        // The validated uniform backdrop also shows through enclosed glyph
        // holes. Leaving it there produces coloured patches inside letters and
        // logos. Pixels sufficiently different from the backdrop stay original.
        for index in 0..<pixelCount where isBackground(index) {
            for channel in 0..<4 { output[index * 4 + channel] = 0 }
        }
        return Result(pixels: output, isTemplate: false, removedBackground: true)
    }

    private static func monochromeEndpoint(pixels: [UInt8], foreground: [Int], background: [Int]) -> Int? {
        var bestEndpoint: Int?
        var bestError = Double.infinity
        for endpoint in [0, 255] {
            let denominator = (0..<3).reduce(0.0) {
                let component = Double(endpoint - background[$1])
                return $0 + component * component
            }
            guard denominator > 0 else { continue }
            var error = 0.0
            var fits = true
            for index in foreground {
                let alpha = coverage(at: index, pixels: pixels, background: background,
                                     endpoint: endpoint, denominator: denominator)
                for channel in 0..<3 {
                    let predicted = Double(background[channel]) + alpha * Double(endpoint - background[channel])
                    let residual = abs(Double(pixels[index * 4 + channel]) - predicted)
                    if residual > monochromeResidual { fits = false; break }
                    error += residual * residual
                }
                if !fits { break }
            }
            if fits, error < bestError {
                bestEndpoint = endpoint
                bestError = error
            }
        }
        return bestEndpoint
    }

    private static func coverage(at index: Int, pixels: [UInt8], background: [Int],
                                 endpoint: Int, denominator: Double) -> Double {
        let projection = (0..<3).reduce(0.0) {
            $0 + Double(Int(pixels[index * 4 + $1]) - background[$1]) * Double(endpoint - background[$1])
        }
        return min(1, max(0, projection / denominator))
    }
}
