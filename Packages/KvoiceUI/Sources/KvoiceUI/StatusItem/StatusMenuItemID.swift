import AppKit

/// The inventory of the status menu's items, in menu order — the contract
/// `AppDelegate.installStatusItem` builds and the shell's debug assertion
/// checks at launch (`StatusMenuItemID.verify(menu:)`). It exists because
/// the shell has no test target: `StatusMenuItemIDTests` pins the list, and
/// an item that leaves the shell without leaving this list trips the
/// assertion on the next Debug launch, so a menu row cannot disappear
/// silently (the standing product rule: nothing is removed unasked).
///
/// Hidden-by-state items (Cancel, Copy Transcript, Insert Transcript Again,
/// Fix in…, Unload Model Now) are still built and still listed; only their
/// `isHidden` follows `updateMenu(for:)`.
public enum StatusMenuItemID: String, CaseIterable, Sendable {
    // Dictation
    case dictationHeader
    case startRecording
    case cancelCurrentDictation
    case copyTranscript
    case insertTranscriptAgain
    case copyLastTranscription
    case status
    case fix
    case unloadModel
    // Transcription
    case transcriptionHeader
    case model
    case language
    case microphone
    // AI
    case aiHeader
    case useAIActions
    case defaultAction
    case configuration
    // App
    case appHeader
    case history
    case settings
    case setupGuide
    case help
    case about
    case quit

    public var identifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("statusMenu.\(rawValue)")
    }

    /// The items of `menu` that carry one of these identifiers, in order.
    public static func present(in menu: NSMenu) -> [StatusMenuItemID] {
        menu.items.compactMap { item in
            guard let identifier = item.identifier?.rawValue,
                  identifier.hasPrefix("statusMenu.") else { return nil }
            return StatusMenuItemID(rawValue: String(identifier.dropFirst("statusMenu.".count)))
        }
    }

    /// The cases `menu` does not carry, in inventory order.
    public static func missing(from menu: NSMenu) -> [StatusMenuItemID] {
        let found = Set(present(in: menu))
        return allCases.filter { !found.contains($0) }
    }

    /// True when `menu` carries every case exactly once, in inventory order.
    public static func isComplete(_ menu: NSMenu) -> Bool {
        present(in: menu) == allCases
    }
}

public extension NSMenuItem {
    /// Stamps the inventory identifier on the item and returns it, so the
    /// shell can tag at the `addItem` call.
    @discardableResult
    func tagged(_ id: StatusMenuItemID) -> NSMenuItem {
        identifier = id.identifier
        return self
    }
}
