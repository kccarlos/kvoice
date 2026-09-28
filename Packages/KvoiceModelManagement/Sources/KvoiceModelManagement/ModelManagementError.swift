import Foundation

public enum ModelManagementError: Error, Sendable, Equatable, LocalizedError {
    case busy
    case cancelled
    case noResumableInstallation
    case noManagedPackage
    case noExternalPackage
    case noVerifiedPackage
    case externalPackageCannotBeDeleted
    case unsupportedModel(String)
    case invalidManifest(String)
    case manifestDigestMismatch
    case packageMissing
    case packageCorrupt(String)
    case downloadFailed(String)
    case runtimeLoadFailed(String)
    case installFailed(String)
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case deleteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .busy:
            return "Model management is unavailable while a dictation job or another model operation is active."
        case .cancelled:
            return "The model download was cancelled."
        case .noResumableInstallation:
            return "There is no paused model download to resume."
        case .noManagedPackage:
            return "No managed model package is installed."
        case .noExternalPackage:
            return "No external model package is selected."
        case .noVerifiedPackage:
            return "No verified model package is ready."
        case .externalPackageCannotBeDeleted:
            return "An external model folder is read-only and cannot be deleted by KVoice."
        case let .unsupportedModel(modelID):
            return "The model is not supported by KVoice v1: " + modelID + "."
        case let .invalidManifest(message):
            return "The model manifest is invalid: " + message + "."
        case .manifestDigestMismatch:
            return "The app-supplied model manifest digest does not match its contents."
        case .packageMissing:
            return "The model package is missing."
        case let .packageCorrupt(message):
            return "The model package failed verification: " + message + "."
        case let .downloadFailed(message):
            return "The model download failed: " + message + "."
        case let .runtimeLoadFailed(message):
            return "The verified model could not be loaded: " + message + "."
        case let .installFailed(message):
            return "The verified model could not be installed: " + message + "."
        case let .insufficientDiskSpace(requiredBytes, availableBytes):
            return ModelInstallationSpaceEstimate.insufficientSpaceMessage(
                requiredBytes: requiredBytes,
                availableBytes: availableBytes
            )
        case let .deleteFailed(message):
            return "The managed model could not be deleted: " + message + "."
        }
    }
}
