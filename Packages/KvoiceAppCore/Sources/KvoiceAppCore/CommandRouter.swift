import KvoiceDomain

/// Translates UI/input intent into domain events. It deliberately does not call
/// AppKit, audio, AX, or network services.
public enum AppCommand: Sendable, Equatable {
    case start(jobID: JobID, prerequisites: StartPrerequisites)
    case stop(jobID: JobID)
    case escape(jobID: JobID)
    case quit
    case dismiss
}

public enum CommandRouter {
    public static func event(for command: AppCommand) -> DictationEvent {
        switch command {
        case .start(let jobID, let prerequisites):
            return .start(jobID: jobID, prerequisites: prerequisites)
        case .stop(let jobID):
            return .stop(jobID: jobID)
        case .escape(let jobID):
            return .escape(jobID: jobID)
        case .quit:
            return .quit
        case .dismiss:
            return .dismiss
        }
    }
}
