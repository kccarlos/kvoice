import Foundation
import XCTest
@testable import KvoiceAppCore
@testable import KvoiceDomain
@testable import KvoiceUI

/// The localization seam for KvoiceDomain and KvoiceAppCore copy: every
/// English sentence the two modules can surface has a translation in
/// `DomainCopy.xcstrings`, and `DomainCopy.localized` resolves whole messages,
/// composed messages, and the recording-cap line in both languages.
final class DomainCopyTests: XCTestCase {
    private var catalog: StringCatalog!
    private var zhHans: DomainCopy.Table!
    /// English resolves to itself: the source language has no table.
    private let english = DomainCopy.Table.dictionary([:])

    override func setUpWithError() throws {
        catalog = try StringCatalog(relativePath: StringCatalog.domainCopy)
        zhHans = .dictionary(catalog.dictionary(for: "zh-Hans"))
    }

    // MARK: Coverage

    func testEveryDomainSentenceAndDisplayNameIsInTheCatalog() {
        let keys = Set(catalog.entries.map(\.key))
        let inventory = DomainUserFacingCopy.all + SelectionActionRunner.Outcome.userFacingMessageInventory
        let missing = inventory.filter { !keys.contains($0) }
        XCTAssertTrue(
            missing.isEmpty,
            "DomainCopy.xcstrings lacks \(missing.count) domain string(s):\n" + missing.joined(separator: "\n")
        )
    }

    func testTheCatalogCarriesNoStringTheDomainNoLongerProduces() {
        let inventory = Set(DomainUserFacingCopy.all + SelectionActionRunner.Outcome.userFacingMessageInventory)
        let extra = catalog.entries.map(\.key).filter { !inventory.contains($0) }
        XCTAssertTrue(
            extra.isEmpty,
            "DomainCopy.xcstrings has \(extra.count) key(s) the domain no longer produces; remove them:\n" + extra.joined(separator: "\n")
        )
    }

    // MARK: Resolution

    func testAWholeMessageResolvesInBothLanguages() {
        let message = KVoiceErrorCode.appCancelled.userFacingMessage
        XCTAssertEqual(DomainCopy.localized(message, table: english), "Dictation cancelled.")
        XCTAssertEqual(DomainCopy.localized(message, table: zhHans), "听写已取消。")
    }

    func testEveryErrorCodeResolvesToSomethingOtherThanEnglishInChinese() {
        for code in KVoiceErrorCode.allCases {
            let message = code.userFacingMessage
            XCTAssertNotEqual(DomainCopy.localized(message, table: zhHans), message, "\(code) is shown in English")
        }
    }

    func testDisplayNamesResolveThroughTheSeam() {
        XCTAssertEqual(DomainCopy.localized(RecordingInteraction.pushToTalk.displayName, table: zhHans), "按住说话")
        XCTAssertEqual(DomainCopy.localized(RecordingDurationLimit.noLimit.displayName, table: zhHans), "无限制")
        XCTAssertEqual(DomainCopy.localized(SpeechComputeUnits.neuralEngineAndCPU.displayName, table: zhHans), "神经网络引擎 + CPU")
        XCTAssertEqual(DomainCopy.localized(RecordingInteraction.pushToTalk.displayName, table: english), "Push-to-Talk")
    }

    func testTheRecordingCapLineIsRecognisedAndReformatted() {
        let summary = CompletionSummary(insertion: .inserted(method: .selectedTextAttribute))
            .attaching(aiFallback: nil, durationCapReached: true, maxRecordingSeconds: 600)
        let line = summary.warningMessage!
        XCTAssertEqual(line, "Recording stopped at the 10-minute limit.")
        XCTAssertEqual(DomainCopy.localized(line, table: english), line)
        XCTAssertEqual(DomainCopy.localized(line, table: zhHans), "录音已在 10 分钟上限处停止。")

        let hour = CompletionSummary(insertion: .inserted(method: .selectedTextAttribute))
            .attaching(aiFallback: nil, durationCapReached: true, maxRecordingSeconds: 3_600)
        XCTAssertEqual(DomainCopy.localized(hour.warningMessage!, table: zhHans), "录音已在 1 小时上限处停止。")
    }

    func testAComposedWarningIsLocalizedSentenceBySentence() {
        // AI fallback + clipboard fallback + cap: three known sentences joined
        // by spaces, the shape `CompletionSummary.attaching` produces.
        let summary = CompletionSummary(
            insertion: .copiedToClipboard(reason: .noFocusedElement),
            warningMessage: ClipboardFallbackReason.noFocusedElement.userFacingMessage
        ).attaching(aiFallback: .aiTimeout, durationCapReached: true, maxRecordingSeconds: 1_800)
        let line = summary.warningMessage!
        XCTAssertEqual(
            line,
            "AI did not respond in time. Inserted the local transcript instead. "
                + "No editable field was focused. Copied the result to the clipboard. "
                + "Recording stopped at the 30-minute limit."
        )
        XCTAssertEqual(
            DomainCopy.localized(line, table: zhHans),
            "AI 未及时响应。已改为插入本地转写文本。 没有聚焦的可编辑输入框。结果已复制到剪贴板。 录音已在 30 分钟上限处停止。"
        )
        XCTAssertEqual(DomainCopy.localized(line, table: english), line)
    }

    func testAnUnknownStringPassesThroughUnchanged() {
        let novel = "A sentence the domain does not produce."
        XCTAssertEqual(DomainCopy.localized(novel, table: zhHans), novel)
        XCTAssertEqual(DomainCopy.localized("", table: zhHans), "")
    }

    /// ADR-025 amendment: the system-managed default's Blocked sentences —
    /// the fixed one as a whole key, the `.unavailable` one as the card's
    /// reason plus the pointer, localized piece by piece.
    func testTheSystemManagedBlockedSentencesResolveInChinese() {
        let missing = BlockReason.systemManagedAssetsMissing.message
        XCTAssertEqual(DomainCopy.localized(missing, table: english), missing)
        XCTAssertEqual(DomainCopy.localized(missing, table: zhHans), "Apple 语音在此 Mac 上尚无所选语言的资源。请在“设置 › 语音模型”中安装。")

        let unavailable = BlockReason.systemManagedUnavailable(SystemManagedUnavailableReason.languageUnsupported.modelFailure).message
        XCTAssertEqual(DomainCopy.localized(unavailable, table: english), unavailable)
        XCTAssertEqual(
            DomainCopy.localized(unavailable, table: zhHans),
            "Apple 语音在此 Mac 上不支持所选的转写语言。 请在“设置 › 语音模型”中选择其他语音模型。"
        )
        let older = BlockReason.systemManagedUnavailable(SystemManagedUnavailableReason.requiresNewerMacOS.modelFailure).message
        XCTAssertNotEqual(DomainCopy.localized(older, table: zhHans), older, "every reason the card can show composes with the hint")
        let blocked = HUDViewState(dictationState: .blocked(.systemManagedAssetsMissing))
        XCTAssertEqual(blocked.detail, missing)
    }

    func testHUDProjectionLocalizesDomainMessages() {
        let blocked = HUDViewState(dictationState: .blocked(.modelLoading))
        // The table is the module bundle here; under SwiftPM it has no
        // `.lproj`, so the projection yields English and proves the seam is
        // on the path (the text arrives through `DomainCopy.localized`).
        XCTAssertEqual(blocked.detail, BlockReason.modelLoading.message)
        XCTAssertEqual(DomainCopy.localized(BlockReason.modelLoading.message, table: zhHans), "转写模型仍在加载。请稍后重试。")
    }
}
