import Foundation
import KvoiceDomain
import os

/// OSLog-backed implementation of the domain diagnostic contract. Only the
/// scalar envelope crosses this boundary; callers cannot pass transcript/audio
/// payloads through this API.
public struct OSLogDiagnosticLogger: DiagnosticLogging {
    private let logger: Logger

    public init(
        subsystem: String = "io.github.kccarlos.kvoice",
        category: String = "diagnostics"
    ) {
        logger = Logger(subsystem: subsystem, category: category)
    }

    public func log(_ event: DiagnosticEvent) async {
        let attributes = event.attributes.publicFields
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: ",")
        let error = event.errorCode?.rawValue ?? "none"
        let result = event.result?.rawValue ?? "none"
        logger.log(
            "event=\(event.name.rawValue, privacy: .public) result=\(result, privacy: .public) error=\(error, privacy: .public) attrs=\(attributes, privacy: .public)"
        )
    }
}

/// Deterministic sink used by app-core and integration tests without requiring
/// an OSLog reader.
public actor InMemoryDiagnosticLogger: DiagnosticLogging {
    private var storedEvents: [DiagnosticEvent] = []

    public init() {}

    public func log(_ event: DiagnosticEvent) async {
        storedEvents.append(event)
    }

    public var events: [DiagnosticEvent] {
        return storedEvents
    }
}
