import Foundation
import KvoiceDomain
import KvoiceTranscription

/// The catalog plus one verified trust anchor per entry (ADR-017).
public struct LoadedSpeechModelCatalog: Sendable {
    public let catalog: SpeechModelCatalog
    /// Keyed by catalog ID. Every kvoice-manifest entry in `catalog` has an
    /// anchor; a missing or mismatching manifest fails the whole load. A
    /// system-managed entry (ADR-025) has none: its assets are the OS's.
    public let anchors: [ModelID: WhisperModelReleaseTrustAnchor]

    public init(catalog: SpeechModelCatalog, anchors: [ModelID: WhisperModelReleaseTrustAnchor]) {
        self.catalog = catalog
        self.anchors = anchors
    }

    public func anchor(for id: ModelID) -> WhisperModelReleaseTrustAnchor? {
        anchors[id]
    }
}

public enum SpeechModelCatalogError: Error, Sendable, Equatable, LocalizedError {
    case catalogMissing
    case catalogUnreadable
    case unsupportedSchema(Int)
    case emptyCatalog
    case duplicateEntry(ModelID)
    case manifestMissing(ModelID)
    case manifestUnreadable(ModelID)
    case manifestDigestMismatch(ModelID)
    case manifestIdentityMismatch(ModelID)
    case unknownRelease(ModelID)

    public var errorDescription: String? {
        switch self {
        case .catalogMissing:
            return "This app release does not contain a speech model catalog."
        case .catalogUnreadable:
            return "The bundled speech model catalog could not be decoded."
        case let .unsupportedSchema(version):
            return "The bundled speech model catalog uses schema \(version), which this app does not understand."
        case .emptyCatalog:
            return "The bundled speech model catalog lists no models."
        case let .duplicateEntry(id):
            return "The bundled speech model catalog lists \(id) twice."
        case let .manifestMissing(id):
            return "The bundled manifest for \(id) is missing."
        case let .manifestUnreadable(id):
            return "The bundled manifest for \(id) could not be decoded."
        case let .manifestDigestMismatch(id):
            return "The bundled manifest for \(id) does not match its recorded digest."
        case let .manifestIdentityMismatch(id):
            return "The bundled manifest for \(id) describes a different model or revision."
        case let .unknownRelease(id):
            return "The catalog entry \(id) names a release this app's runtime cannot validate."
        }
    }
}

public protocol SpeechModelCatalogLoading: Sendable {
    func load() throws -> LoadedSpeechModelCatalog
}

/// Loads the catalog and its manifests from this package's resource bundle
/// and fails closed on any inconsistency: a manifest whose canonical digest
/// differs from the catalog's record, whose identity differs from its entry,
/// or whose release the runtime validator does not know, refuses the whole
/// catalog. Nothing here touches the network.
public struct BundledSpeechModelCatalogLoader: SpeechModelCatalogLoading {
    public static let catalogResourceName = "SpeechModelCatalog"
    public static let manifestsSubdirectory = "Manifests"

    private let bundle: Bundle

    /// Reads from this package's resource bundle.
    public init() {
        bundle = .module
    }

    /// Reads from an arbitrary bundle with the same layout (tests).
    public init(bundle: Bundle) {
        self.bundle = bundle
    }

    public func load() throws -> LoadedSpeechModelCatalog {
        guard let catalogURL = bundle.url(forResource: Self.catalogResourceName, withExtension: "json") else {
            throw SpeechModelCatalogError.catalogMissing
        }
        let catalogData: Data
        do {
            catalogData = try Data(contentsOf: catalogURL)
        } catch {
            throw SpeechModelCatalogError.catalogUnreadable
        }
        return try Self.load(
            catalogData: catalogData,
            manifestData: { id in
                guard let url = bundle.url(
                    forResource: id,
                    withExtension: "json",
                    subdirectory: Self.manifestsSubdirectory
                ) else { return nil }
                return try Data(contentsOf: url)
            }
        )
    }

    /// The verification half, separated so tests can feed bytes directly.
    public static func load(
        catalogData: Data,
        manifestData: (String) throws -> Data?
    ) throws -> LoadedSpeechModelCatalog {
        let catalog: SpeechModelCatalog
        do {
            catalog = try JSONDecoder().decode(SpeechModelCatalog.self, from: catalogData)
        } catch {
            throw SpeechModelCatalogError.catalogUnreadable
        }
        guard catalog.schemaVersion == SpeechModelCatalog.currentSchemaVersion else {
            throw SpeechModelCatalogError.unsupportedSchema(catalog.schemaVersion)
        }
        guard !catalog.entries.isEmpty else {
            throw SpeechModelCatalogError.emptyCatalog
        }

        var anchors: [ModelID: WhisperModelReleaseTrustAnchor] = [:]
        var seen = Set<ModelID>()
        for entry in catalog.entries {
            guard seen.insert(entry.id).inserted else {
                throw SpeechModelCatalogError.duplicateEntry(entry.id)
            }
            // ADR-025: a system-managed entry has no manifest to verify —
            // the platform owns and verifies its assets — so it gets no
            // anchor and must not pretend to have one.
            if entry.isSystemManaged {
                guard entry.manifestResource.isEmpty, entry.manifestSHA256.isEmpty, entry.downloadBytes == 0 else {
                    throw SpeechModelCatalogError.manifestIdentityMismatch(entry.id)
                }
                continue
            }
            let data: Data?
            do {
                data = try manifestData(entry.manifestResource)
            } catch {
                throw SpeechModelCatalogError.manifestUnreadable(entry.id)
            }
            guard let data else {
                throw SpeechModelCatalogError.manifestMissing(entry.id)
            }
            let anchor: WhisperModelReleaseTrustAnchor
            do {
                anchor = try WhisperModelReleaseTrustAnchor(
                    manifestData: data,
                    manifestSHA256: entry.manifestSHA256
                )
            } catch {
                throw SpeechModelCatalogError.manifestUnreadable(entry.id)
            }
            guard (try? WhisperModelReleaseTrustAnchor.digest(for: anchor.manifest)) == entry.manifestSHA256 else {
                throw SpeechModelCatalogError.manifestDigestMismatch(entry.id)
            }
            guard anchor.manifest.modelID == entry.id,
                  anchor.manifest.source.revision == entry.revision,
                  anchor.manifest.family == entry.family else {
                throw SpeechModelCatalogError.manifestIdentityMismatch(entry.id)
            }
            // ADR-019: every runnable entry must name a release in the pinned
            // table, under the runtime the entry claims; a reserved runtime
            // with no adapter has no rows and is simply unavailable.
            if entry.runtime.isAvailableInThisBuild {
                guard let release = PinnedModelReleases.release(matching: anchor.manifest),
                      release.runtime == entry.runtime else {
                    throw SpeechModelCatalogError.unknownRelease(entry.id)
                }
            }
            anchors[entry.id] = anchor
        }
        return LoadedSpeechModelCatalog(catalog: catalog, anchors: anchors)
    }
}
