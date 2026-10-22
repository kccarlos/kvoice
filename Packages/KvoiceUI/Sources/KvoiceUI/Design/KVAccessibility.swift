import Foundation

/// Accessibility helpers shared by every surface.
public enum KVAccessibility {
    /// The Accessibility value of a selectable chip, card, row or tab.
    /// On macOS SwiftUI's `.isSelected` trait reaches no attribute a client
    /// reads, so VoiceOver (and the UI smoke harness) could not tell which
    /// recorder style, AI action, configuration or panel chip was current
    /// (Q2, 2026-10-21). Pair it with the trait.
    public static func selectionValue(_ isSelected: Bool) -> String {
        isSelected ? String(localized: "Selected", bundle: .module) : ""
    }
}
