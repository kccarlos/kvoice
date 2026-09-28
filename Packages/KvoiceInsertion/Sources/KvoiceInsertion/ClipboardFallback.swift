import Foundation
import AppKit
import KvoiceDomain

/// Performs the one documented clipboard mutation: an insertion failure copies
/// the final text and reports why direct AX mutation was refused.
public struct ClipboardFallback: Sendable {
    private let writer: any ClipboardWriting

    public init(writer: any ClipboardWriting = SystemClipboardWriter()) {
        self.writer = writer
    }

    public func copy(
        _ text: String,
        reason: ClipboardFallbackReason
    ) throws -> InsertionOutcome {
        do {
            try writer.write(text)
            return .copiedToClipboard(reason: reason)
        } catch let error as KVoiceError {
            throw error
        } catch {
            throw KVoiceError(code: .clipboardWriteFailed)
        }
    }
}

public struct SystemClipboardWriter: ClipboardWriting {
    public init() {}

    public func write(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        guard pasteboard.clearContents() != 0,
              pasteboard.setString(text, forType: .string)
        else {
            throw KVoiceError(code: .clipboardWriteFailed)
        }
    }
}
