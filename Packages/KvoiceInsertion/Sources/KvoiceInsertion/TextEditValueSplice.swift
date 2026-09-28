import Foundation

/// The value-splice fallback used only for TextEdit.  All offsets are
/// validated against `NSString.length`, which is measured in UTF-16 code
/// units just like the AX selected-text-range contract.
public enum TextEditValueSplice {
    public struct Result: Sendable, Equatable {
        public let replacementValue: String
        public let caret: AXTextRange

        public init(replacementValue: String, caret: AXTextRange) {
            self.replacementValue = replacementValue
            self.caret = caret
        }
    }

    public enum SpliceError: Error, Sendable, Equatable {
        case invalidRange
        case valueTooLarge
        case insertionTooLarge
        case rangeTooLarge
        case resultTooLarge
    }

    public static func replacing(
        value: String,
        selectedRange: AXTextRange,
        with insertion: String
    ) throws -> Result {
        guard AXInsertionLimits.isBounded(value) else {
            throw SpliceError.valueTooLarge
        }
        guard AXInsertionLimits.isBounded(insertion) else {
            throw SpliceError.insertionTooLarge
        }
        guard AXInsertionLimits.isBounded(selectedRange) else {
            throw SpliceError.rangeTooLarge
        }

        let current = value as NSString
        guard selectedRange.location >= 0,
              selectedRange.length >= 0,
              selectedRange.location <= current.length,
              selectedRange.length <= current.length - selectedRange.location
        else {
            throw SpliceError.invalidRange
        }

        let insertionUTF16Length = insertion.utf16.count
        let retainedUTF16Length = current.length - selectedRange.length
        guard retainedUTF16Length <= AXInsertionLimits.maxUTF16Units - insertionUTF16Length,
              value.utf8.count <= AXInsertionLimits.maxUTF8Bytes - insertion.utf8.count
        else {
            throw SpliceError.resultTooLarge
        }

        let nsRange = NSRange(
            location: selectedRange.location,
            length: selectedRange.length
        )
        let replacementValue = current.replacingCharacters(in: nsRange, with: insertion)
        let caretLocation = selectedRange.location + insertionUTF16Length
        guard AXInsertionLimits.isBounded(replacementValue),
              AXInsertionLimits.isBounded(
                AXTextRange(location: caretLocation, length: 0)
              )
        else {
            throw SpliceError.resultTooLarge
        }
        return Result(
            replacementValue: replacementValue,
            caret: AXTextRange(location: caretLocation, length: 0)
        )
    }
}
