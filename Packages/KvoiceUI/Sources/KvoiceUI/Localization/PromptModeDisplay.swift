import Foundation
import KvoiceDomain

/// The built-in AI actions' names and descriptions in the interface
/// language (2026-10-22). A `PromptMode`'s `name` and `summary` are stored,
/// user-editable data and stay English for the built-ins: the domain
/// compares them with the shipped text (`isRevisedBuiltIn`, Reset, the 0.1.6
/// rule that an unedited built-in picks up new instructions), so
/// translating the stored value would make every untouched built-in read as
/// edited and would not follow a language switch. These accessors localize
/// at display time instead, keyed by the shipped English
/// (`shippedNameKey` / `shippedSummaryKey`, `DomainCopy.xcstrings`), and
/// return a renamed or user-created action's text exactly as typed.
///
/// Every surface that shows an action's name reads `displayTitle`: the AI
/// Actions grid, default strip, detail sheet and slot pickers, the status
/// panel's chips and the menu, the recorder chip and processing badge,
/// Home, the setup wizard and the App Intents entity. Trigger words, App
/// Intents matching and settings stay on the stored name.
public extension PromptMode {
    /// The name to show: the localized shipped name for an unrenamed
    /// built-in, otherwise `menuTitle` verbatim.
    var displayTitle: String { displayTitle(table: .module) }

    /// The description to show, under the same rule.
    var displaySummary: String { displaySummary(table: .module) }

    func displayTitle(table: DomainCopy.Table) -> String {
        guard let key = shippedNameKey else { return menuTitle }
        return table.lookup(key) ?? key
    }

    func displaySummary(table: DomainCopy.Table) -> String {
        guard let key = shippedSummaryKey else { return summary }
        return table.lookup(key) ?? key
    }
}
