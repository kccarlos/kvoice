import Foundation

/// Auto Daily Export: append every completed dictation to `YYYY-MM-DD.md`
/// inside a folder the user chose.
///
/// Only the *preference* lives here. The folder itself is a security-scoped
/// bookmark — a grant that survives relaunches and moves but is meaningless
/// on any other Mac — so since ADR-022 slice 5 it is `LocalState.exportFolder`
/// (`ExportFolderGrant`), never part of an exported settings file. A file
/// from before the split still carries `autoExportFolderBookmark` /
/// `autoExportFolderDisplayPath` under this key; the decoder ignores them
/// (the local-state store migrated them once, `LocalState.seeded`). A
/// bookmark that no longer resolves, or resolves stale, needs the user to
/// re-authorize; the Data & Privacy section shows that state and the
/// exporter skips silently until it is fixed.
public struct ExportSettings: Codable, Sendable, Equatable {
    public var autoDailyExportEnabled: Bool

    public init(autoDailyExportEnabled: Bool = false) {
        self.autoDailyExportEnabled = autoDailyExportEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case autoDailyExportEnabled
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        autoDailyExportEnabled = try values.decodeIfPresent(Bool.self, forKey: .autoDailyExportEnabled) ?? false
    }
}

/// Resolution of the auto-export folder bookmark.
public enum ExportFolderAccess: Sendable, Equatable {
    /// No folder has been chosen.
    case notConfigured
    /// The bookmark resolved to an existing folder.  Callers bracket file
    /// work with `startAccessingSecurityScopedResource()` / `stop…`.
    case available(URL)
    /// The bookmark exists but no longer resolves (folder deleted, or the grant
    /// was lost) or resolved stale: the user must choose the folder again.
    case needsReauthorization

    /// Makes a security-scoped bookmark for a folder the user just picked.
    public static func makeBookmark(for folder: URL) throws -> Data {
        try folder.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolves a stored bookmark.  Stale bookmarks are reported as needing
    /// re-authorization rather than silently refreshed, because refreshing
    /// requires the user's grant again anyway.
    ///
    /// A bookmark *follows* a folder that is moved or renamed, which is
    /// exactly what an export destination must not do: the user chose a
    /// place, not an inode, and a folder dragged to the Trash would keep
    /// receiving transcripts.  So when `displayPath` (the path at the time
    /// of choosing) is known, a resolution that lands anywhere else — or
    /// anywhere inside a `.Trash` — also needs re-authorization.
    public static func resolve(
        _ bookmark: Data?,
        displayPath: String? = nil,
        fileManager: FileManager = .default
    ) -> ExportFolderAccess {
        guard let bookmark else { return .notConfigured }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return .needsReauthorization
        }
        if isStale { return .needsReauthorization }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .needsReauthorization
        }
        let resolvedPath = canonicalPath(url)
        if resolvedPath.contains("/.Trash/") { return .needsReauthorization }
        if let displayPath, canonicalPath(URL(fileURLWithPath: displayPath, isDirectory: true)) != resolvedPath {
            return .needsReauthorization
        }
        return .available(url)
    }

    /// `/var/folders/…` and `/private/var/folders/…` are the same place.
    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    public var url: URL? {
        if case .available(let url) = self { return url }
        return nil
    }
}
