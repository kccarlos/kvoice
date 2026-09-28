import AppIntents
import KvoiceAppCore
import KvoiceDomain

/// A saved AI action (`PromptMode`) as Shortcuts sees it: the id and the
/// name, nothing else. The prompt text never leaves the app; Start
/// Dictation only needs the id, which the controller resolves against the
/// settings snapshot at the start edge (`DictationStartOptions.aiActionID`).
struct AIActionEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("AI Action", table: "Shell")
    )
    static let defaultQuery = AIActionEntityQuery()

    let id: UUID
    let name: String

    init(_ action: PromptMode) {
        id = action.id
        name = action.menuTitle
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

/// Resolves the parameter from the user's saved actions. By id when
/// Shortcuts re-runs a stored shortcut, by name when the user types in the
/// picker, and the whole list as suggestions. The lookup itself lives in
/// `DictationCommandService.aiActions` so it is unit-tested; this type only
/// wraps the result.
struct AIActionEntityQuery: EntityStringQuery {
    @Dependency
    private var service: DictationCommandService

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [AIActionEntity] {
        service.aiActions(ids: identifiers).map(AIActionEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [AIActionEntity] {
        service.aiActions(matching: string).map(AIActionEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [AIActionEntity] {
        service.aiActions().map(AIActionEntity.init)
    }
}
