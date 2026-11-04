import Foundation

/// An untranslated message tree. Keep this value in model state and render it
/// at the presentation boundary so existing notices follow language changes.
/// Only literals/interpolations create keys; external names and errors must
/// explicitly use `verbatim` and are never looked up or rewritten.
public struct LocalizedMessage: Hashable, Sendable, ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    private indirect enum Content: Hashable, Sendable {
        case key(String, [LocalizedMessage])
        case verbatim(String)
        case joined([LocalizedMessage], String)
    }

    private let content: Content
    private static let tokenExpression = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)

    public init(stringLiteral value: String) { content = .key(value, []) }
    public init(stringInterpolation: StringInterpolation) {
        content = .key(stringInterpolation.key, stringInterpolation.arguments)
    }
    public init(_ message: LocalizedMessage) { self = message }
    private init(content: Content) { self.content = content }

    public static func verbatim(_ value: String) -> Self { Self(content: .verbatim(value)) }
    public static func joined(_ messages: [Self], separator: String) -> Self {
        Self(content: .joined(messages, separator))
    }
    public static func + (lhs: Self, rhs: Self) -> Self { .joined([lhs, rhs], separator: "") }
    public var sourceText: String { rendered { $0 } }
    public var isEmpty: Bool { sourceText.isEmpty }

    public func rendered(lookup: (String) -> String) -> String {
        switch content {
        case .verbatim(let value): return value
        case .joined(let messages, let separator):
            return messages.map { $0.rendered(lookup: lookup) }.joined(separator: separator)
        case .key(let key, let arguments):
            let template = lookup(key)
            // Replace tokens in the template exactly once. Interpolated app
            // names containing braces, percent signs or Chinese stay opaque.
            let source = template as NSString
            var result = template
            for match in Self.tokenExpression.matches(in: template, range: NSRange(location: 0, length: source.length)).reversed() {
                guard let index = Int(source.substring(with: match.range(at: 1))), arguments.indices.contains(index),
                      let range = Range(match.range, in: result) else { continue }
                result.replaceSubrange(range, with: arguments[index].rendered(lookup: lookup))
            }
            return result
        }
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        fileprivate var key = ""
        fileprivate var arguments: [LocalizedMessage] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity)
            arguments.reserveCapacity(interpolationCount)
        }
        public mutating func appendLiteral(_ literal: String) { key += literal }
        public mutating func appendInterpolation(_ message: LocalizedMessage) {
            key += "{\(arguments.count)}"
            arguments.append(message)
        }
        public mutating func appendInterpolation<T: CustomStringConvertible>(_ value: T) {
            appendInterpolation(.verbatim(value.description))
        }
    }
}

public extension Collection where Element == LocalizedMessage {
    func joined(separator: String) -> LocalizedMessage { .joined(Array(self), separator: separator) }
}

/// App-owned errors preserve their message tree through nested error paths.
/// Foundation's description remains available for logs and external callers.
public protocol LocalizedMessageError: LocalizedError {
    var localizedMessage: LocalizedMessage { get }
}

public extension LocalizedMessageError {
    var errorDescription: String? { localizedMessage.sourceText }
}

public struct MessageFailure: LocalizedMessageError, Sendable {
    public let localizedMessage: LocalizedMessage
    public init(_ message: LocalizedMessage) { localizedMessage = message }
}

public extension Error {
    var localizedMessage: LocalizedMessage {
        (self as? any LocalizedMessageError)?.localizedMessage ?? .verbatim(localizedDescription)
    }
}
