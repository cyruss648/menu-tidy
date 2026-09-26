/// A panel reflects accepted rules or a verified physical observation. Draft
/// choices are deliberately not inputs: editing a form must not reveal an item.
public enum HiddenItemsPanelPolicy {
    public static func includes(
        savedVisibility: ItemVisibility?,
        observedVisibility: ItemVisibility?,
        includeAlwaysHidden: Bool
    ) -> Bool {
        switch savedVisibility ?? observedVisibility {
        case .collapsible: true
        case .alwaysHidden: includeAlwaysHidden
        case .visible, nil: false
        }
    }
}
