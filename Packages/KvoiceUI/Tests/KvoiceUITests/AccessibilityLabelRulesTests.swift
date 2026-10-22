import Foundation
import XCTest

/// Source rules for accessibility labels that unit tests cannot observe
/// any other way (found by the UI smoke harness, Q2 2026-10-21).
final class AccessibilityLabelRulesTests: XCTestCase {
    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KvoiceUITests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // KvoiceUI
            .appendingPathComponent("Sources/KvoiceUI")
    }

    private static func sources() throws -> [(name: String, lines: [String])] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil))
        return try enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { url in
                (url.lastPathComponent,
                 try String(contentsOf: url, encoding: .utf8)
                     .components(separatedBy: "\n"))
            }
    }

    private static func indentation(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    /// The modifier chain a line belongs to: the neighbouring lines at the
    /// same indentation that start with ".", skipping deeper (argument)
    /// lines and comments.
    static func modifierChain(around index: Int, in lines: [String]) -> [String] {
        let level = indentation(lines[index])
        func belongs(_ line: String) -> Bool? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("//") { return nil } // skip
            let indent = indentation(line)
            if indent > level { return nil }
            return indent == level && trimmed.hasPrefix(".")
        }
        var chain = [lines[index]]
        for step in [-1, 1] {
            var i = index + step
            scan: while lines.indices.contains(i) {
                switch belongs(lines[i]) {
                case nil: break
                case true?: chain.append(lines[i])
                case false?: break scan
                }
                i += step
            }
        }
        return chain
    }

    /// Selectable text is an AppKit text element under SwiftUI; an
    /// `.accessibilityLabel` on it is applied as an override on that
    /// element, and resolving the label read the element's own label again.
    /// An Accessibility walk of History (what VoiceOver does) overflowed the
    /// stack on the transcript box (KNOWN_ISSUES P1, 2026-10-21). Put the
    /// label on a container instead.
    func testNoAccessibilityLabelSitsOnSelectableText() throws {
        var offenders: [String] = []
        var seen = 0
        for file in try Self.sources() {
            for (i, line) in file.lines.enumerated() where line.contains(".textSelection(.enabled)") {
                seen += 1
                let chain = Self.modifierChain(around: i, in: file.lines)
                if chain.contains(where: { $0.contains(".accessibilityLabel(") }) {
                    offenders.append("\(file.name):\(i + 1)")
                }
            }
        }
        XCTAssertGreaterThan(seen, 5, "the scan found no selectable text; the rule is not looking")
        XCTAssertEqual(offenders, [])
    }

    func testModifierChainStopsAtTheEnclosingView() {
        let lines = [
            "        VStack {",
            "            Text(value)",
            "                .textSelection(.enabled)",
            "                .font(.body)",
            "        }",
            "        .accessibilityLabel(\"Outer\")",
        ]
        XCTAssertEqual(Self.modifierChain(around: 2, in: lines).count, 2)
        let direct = [
            "            Text(value)",
            "                .textSelection(.enabled)",
            "                .background(Color.red, in: Capsule(",
            "                    style: .continuous))",
            "                // a comment",
            "                .accessibilityLabel(\"Inner\")",
        ]
        XCTAssertTrue(Self.modifierChain(around: 1, in: direct).contains { $0.contains("Inner") })
    }

    /// `"\(key)"` on a `LocalizedStringKey` spells out its debug description
    /// — History's Details rows read "LocalizedStringKey(key: \"Model\", …)
    /// : Unknown" to VoiceOver. Use `Text(key)` instead.
    func testNoLocalizedStringKeyIsInterpolatedIntoAString() throws {
        var offenders: [String] = []
        let parameter = try NSRegularExpression(pattern: #"(\w+)\s*:\s*LocalizedStringKey\b"#)
        for file in try Self.sources() {
            // Within each function whose signature takes a key, until the
            // next declaration at the same or a shallower indentation.
            for (start, signature) in file.lines.enumerated()
            where signature.contains(" func ") && signature.contains("LocalizedStringKey") {
                let names = parameter.matches(in: signature, range: NSRange(signature.startIndex..., in: signature))
                    .compactMap { Range($0.range(at: 1), in: signature).map { String(signature[$0]) } }
                let level = Self.indentation(signature)
                var i = start + 1
                while i < file.lines.count {
                    let line = file.lines[i]
                    if line.contains(" func "), Self.indentation(line) <= level { break }
                    if !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                        for name in names where line.contains("\\(\(name))") {
                            offenders.append("\(file.name):\(i + 1) \\(\(name))")
                        }
                    }
                    i += 1
                }
            }
        }
        XCTAssertEqual(offenders, [])
    }

    /// `.isSelected` alone reaches no Accessibility attribute on macOS, so
    /// every element that sets it must also carry the selection value
    /// (Q2: recorder style cards, AI action cards, panel chips).
    func testEverySelectedTraitAlsoReportsTheSelectionValue() throws {
        var offenders: [String] = []
        for file in try Self.sources() {
            for (i, line) in file.lines.enumerated()
            where line.contains(".accessibilityAddTraits(") && line.contains(".isSelected") {
                let chain = Self.modifierChain(around: i, in: file.lines)
                if !chain.contains(where: { $0.contains(".accessibilityValue(") }) {
                    offenders.append("\(file.name):\(i + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [])
    }
}
