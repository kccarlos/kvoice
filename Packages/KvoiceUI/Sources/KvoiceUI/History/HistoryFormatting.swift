import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KvoiceDomain

// What History says about an entry — mode, outcome, dates, titles and
// VoiceOver summaries (split from `HistoryView.swift`, Q2b).

extension DictationMode {
    var displayName: String {
        switch self {
        case .off: return String(localized: "Off", bundle: .module)
        case .polish: return String(localized: "Polish", bundle: .module)
        case .translate: return String(localized: "Translate", bundle: .module)
        }
    }

    var symbolName: String {
        switch self {
        case .off: return "waveform"
        case .polish: return "wand.and.stars"
        case .translate: return "globe"
        }
    }
}

extension HistoryAIStatus {
    var displayName: String {
        switch self {
        case .off: return String(localized: "Off", bundle: .module)
        case .succeeded: return String(localized: "Succeeded", bundle: .module)
        case .failed: return String(localized: "Failed, raw transcript used", bundle: .module)
        case .cancelledFallback: return String(localized: "Cancelled, raw transcript used", bundle: .module)
        }
    }
}

extension InsertionOutcome {
    func displayName(isFile: Bool) -> String {
        switch self {
        case .inserted: return String(localized: "Inserted", bundle: .module)
        case .copiedToClipboard: return String(localized: "Copied to Clipboard", bundle: .module)
        case .deliveredInApp: return isFile ? String(localized: "Not inserted", bundle: .module) : String(localized: "Shown in Setup", bundle: .module)
        case .abortedAtTermination: return String(localized: "Aborted at Quit", bundle: .module)
        }
    }

    func detailName(isFile: Bool) -> String {
        switch self {
        case .inserted(let method):
            switch method {
            case .selectedTextAttribute: return String(localized: "Inserted via Accessibility", bundle: .module)
            case .textEditValueSplice: return String(localized: "Inserted via Accessibility (value splice)", bundle: .module)
            case .typedKeyboardEvents: return String(localized: "Typed into the application", bundle: .module)
            }
        case .copiedToClipboard(let reason):
            return String(localized: "Copied to Clipboard (\(reason.displayName))", bundle: .module)
        case .deliveredInApp:
            return isFile ? String(localized: "Transcribed from a file; nothing was inserted", bundle: .module) : String(localized: "Shown in the Setup window", bundle: .module)
        case .abortedAtTermination:
            return String(localized: "KVoice quit before the text was inserted", bundle: .module)
        }
    }
}

extension ClipboardFallbackReason {
    var displayName: String {
        switch self {
        case .noFrontmostApplication: return String(localized: "no frontmost app", bundle: .module)
        case .targetApplicationChanged: return String(localized: "app changed", bundle: .module)
        case .noFocusedElement: return String(localized: "no focused field", bundle: .module)
        case .notEditable: return String(localized: "field not editable", bundle: .module)
        case .secureTarget: return String(localized: "secure field", bundle: .module)
        case .unsupportedValueType: return String(localized: "unsupported field", bundle: .module)
        case .setFailed: return String(localized: "insertion refused", bundle: .module)
        case .verifyFailed: return String(localized: "insertion not verified", bundle: .module)
        case .timeout: return String(localized: "timed out", bundle: .module)
        case .permissionNotGranted: return String(localized: "permission missing", bundle: .module)
        case .textTooLarge: return String(localized: "too long to type", bundle: .module)
        }
    }
}

extension String {
    var oneLinePreview: String {
        replacingOccurrences(of: "\n", with: " ")
    }
}

extension Date {
    /// UI v2 fidelity F3b: the detail's title, Window.dc's "Today 9:38":
    /// Today / Yesterday and the time, else the short date and time.
    var historyDetailTitle: String {
        let time = formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return String(localized: "Today \(time)", bundle: .module) }
        if calendar.isDateInYesterday(self) { return String(localized: "Yesterday \(time)", bundle: .module) }
        return formatted(date: .abbreviated, time: .shortened)
    }
}

extension Date {
    /// Clock time for today, a short date for anything older.
    ///
    /// Rows used to show the time alone, which made a list spanning several days
    /// a column of ambiguous times with no way to tell yesterday from last week.
    var historyRowLabel: String {
        Calendar.current.isDateInToday(self)
            ? formatted(date: .omitted, time: .shortened)
            : formatted(date: .abbreviated, time: .shortened)
    }
}

extension HistoryEntry {
    /// UI v2 fidelity F3b: the row's first line. Window.dc shows the app;
    /// history keeps no app name (J.5), so the row says where the text
    /// went.
    var rowTitle: String {
        insertionOutcome.displayName(isFile: isFileTranscription)
    }

    /// The detail's meta line (Window.dc "0:12 · Clean Up · Inserted via
    /// Accessibility"): length, AI mode or "Transcribed file", where the
    /// text went.
    var detailMeta: String {
        var parts: [String] = []
        if let milliseconds = recordingDurationMilliseconds {
            parts.append(AudioPlaybackStrip.clock(TimeInterval(milliseconds) / 1_000))
        }
        if isFileTranscription {
            parts.append(String(localized: "Transcribed file", bundle: .module))
        } else if mode != .off {
            parts.append(mode.displayName)
        }
        parts.append(insertionOutcome.detailName(isFile: isFileTranscription))
        return parts.joined(separator: " · ")
    }

    /// The AI fact (Window.dc "Clean Up · Local Ollama · 0.8 s"; the
    /// action and configuration names are not stored): the outcome and the
    /// time it took.
    var aiDetail: String {
        var parts = [aiStatus.displayName]
        if let milliseconds = aiDurationMilliseconds {
            parts.append(HistoryDashboardView.seconds(milliseconds))
        }
        return parts.joined(separator: " · ")
    }
}

extension HistoryEntry {
    /// The D.10 sentence for a row whose AI stage did not complete: what
    /// happened and what kvoice did with the text. Nil on the happy path.
    var aiFallbackSummary: String? {
        switch aiStatus {
        case .failed:
            return String(localized: "AI did not respond. The raw transcript was used instead.", bundle: .module)
        case .cancelledFallback:
            return String(localized: "AI processing was cancelled. The raw transcript was used instead.", bundle: .module)
        case .off, .succeeded:
            return errorCode == nil ? nil : String(localized: "AI reported a problem. The raw transcript was used instead.", bundle: .module)
        }
    }

    var accessibilitySummary: String {
        var parts = [finalText.oneLinePreview, isFileTranscription ? String(localized: "File", bundle: .module) : mode.displayName, insertionOutcome.displayName(isFile: isFileTranscription)]
        if isFallback {
            parts.append("Fallback")
        }
        parts.append(createdAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: ". ")
    }
}

extension HistoryEntry {
    /// The Details "Target" row. `targetClass` is the diagnostics role
    /// class (J.5), never a bundle ID; the row showed its raw value
    /// ("other", "textEdit") until Q2.
    static func targetDisplayName(_ targetClass: String) -> String {
        switch targetClass {
        case TargetClass.textEdit.rawValue: return "TextEdit"
        case TargetClass.other.rawValue: return String(localized: "Another app", bundle: .module)
        case TargetClass.none.rawValue: return String(localized: "No app in front", bundle: .module)
        case TargetClass.secure.rawValue: return String(localized: "Secure text field", bundle: .module)
        case HistoryEntry.fileTargetClass: return String(localized: "Audio or video file", bundle: .module)
        default: return targetClass
        }
    }
}
