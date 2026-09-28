# TextEdit insertion fixtures

All ranges are expressed in UTF-16 code units, matching `NSRange` and the Accessibility selected-text-range contract. Successful cases require direct AX mutation, a collapsed caret immediately after the inserted text, and an unchanged clipboard content/change count. Target-affinity and secure-field cases require no target mutation and an explicit clipboard fallback.

The fixtures are deterministic logic cases; they do not require TextEdit or Accessibility permission to validate. A macOS integration harness can reuse the same values against plain/rich TextEdit documents.
