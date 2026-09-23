/// The section selected for a menu bar item. Unknown persisted categories are
/// rejected by Codable rather than silently changing which items are visible.
public enum ItemVisibility: String, CaseIterable, Codable, Identifiable, Sendable {
    case visible
    case collapsible
    case alwaysHidden

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .visible: "常驻显示"
        case .collapsible: "收起后隐藏"
        case .alwaysHidden: "始终隐藏"
        }
    }

    public var detail: String {
        switch self {
        case .visible: "保留在菜单栏中，不随开关收起。"
        case .collapsible: "收起时隐藏，展开时显示。"
        case .alwaysHidden: "展开时也保持隐藏，管理图标或临时显示全部时可见。"
        }
    }
}

/// A user's choice for one stable menu bar item identifier.
public struct ItemRule: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var bundleIdentifier: String?
    public var visibility: ItemVisibility

    public init(id: String, name: String, bundleIdentifier: String?, visibility: ItemVisibility) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.visibility = visibility
    }
}

/// Serializable choices independent of how the app stores them or discovers
/// currently running menu bar items. Missing items retain their saved choices.
public struct ItemRuleBook: Codable, Equatable, Sendable {
    public private(set) var rules: [String: ItemRule]

    private enum CodingKeys: String, CodingKey {
        case rules
    }

    public init(rules: [String: ItemRule] = [:]) {
        self.rules = rules
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedRules = try container.decode([String: ItemRule].self, forKey: .rules)
        guard decodedRules.allSatisfy({ $0.key == $0.value.id }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .rules,
                in: container,
                debugDescription: "Rule dictionary keys must match the corresponding item IDs."
            )
        }
        rules = decodedRules
    }

    public mutating func set(_ rule: ItemRule) {
        rules[rule.id] = rule
    }

    public mutating func remove(id: String) {
        rules.removeValue(forKey: id)
    }

    public func rule(for id: String) -> ItemRule? {
        rules[id]
    }
}

/// Chooses which section boundary should push its left-hand neighbours out of
/// view. Use only one large spacer at a time: macOS 27 may drop oversized status
/// items if both boundaries compete for the available menu bar region.
public enum MenuBarSectionPolicy {
    public static func separatorVisibility(
        isCollapsed: Bool,
        hasAlwaysHidden: Bool,
        isManaging: Bool,
        temporarilyRevealingAll: Bool
    ) -> (collapseRegular: Bool, collapseAlways: Bool) {
        guard !isManaging, !temporarilyRevealingAll else {
            return (collapseRegular: false, collapseAlways: false)
        }
        if isCollapsed {
            // The regular boundary also hides the always-hidden section to its left.
            return (collapseRegular: true, collapseAlways: false)
        }
        return (collapseRegular: false, collapseAlways: hasAlwaysHidden)
    }
}
