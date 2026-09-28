import Foundation
import XCTest
@testable import KvoiceDomain

/// ADR-027 item 6: one test per branch of the rule that decides when the
/// shell may ask the Private Cloud Compute framework anything.
final class PrivateCloudComputeQueryPolicyTests: XCTestCase {
    private let pcc = AIConfiguration(name: "Apple servers", kind: .privateCloudCompute)
    private let onDevice = AIConfiguration(name: "On this Mac", kind: .appleIntelligence)

    private func decide(
        _ trigger: PrivateCloudComputeQueryPolicy.Trigger,
        refusal: AIProviderUnavailableReason? = nil,
        aiEnabled: Bool = true,
        configurations: [AIConfiguration]? = nil,
        active: AIProviderTransport = .privateCloudCompute
    ) -> PrivateCloudComputeQueryPolicy.Decision {
        PrivateCloudComputeQueryPolicy.decide(
            trigger: trigger,
            staticRefusal: refusal,
            aiEnabled: aiEnabled,
            configurations: configurations ?? [pcc, onDevice],
            activeTransport: active
        )
    }

    func testAStaticRefusalWinsForEveryTriggerAndAsksNothing() {
        for trigger in PrivateCloudComputeQueryPolicy.Trigger.allCases {
            XCTAssertEqual(decide(trigger, refusal: .notInThisEdition), .staticRefusal(.notInThisEdition))
            XCTAssertEqual(decide(trigger, refusal: .buildNotEntitled, aiEnabled: false), .staticRefusal(.buildNotEntitled))
        }
    }

    func testAIOffClearsTheFacts() {
        for trigger in PrivateCloudComputeQueryPolicy.Trigger.allCases {
            XCTAssertEqual(decide(trigger, aiEnabled: false), .clear, "\(trigger)")
        }
    }

    func testNoSavedConfigurationClearsTheFacts() {
        for trigger in PrivateCloudComputeQueryPolicy.Trigger.allCases {
            XCTAssertEqual(decide(trigger, configurations: [onDevice], active: .appleIntelligence), .clear, "\(trigger)")
        }
    }

    func testActivationReadsAvailabilityAndTheQuotaOnlyWhenActive() {
        XCTAssertEqual(decide(.activation), .read(includeQuota: true))
        XCTAssertEqual(decide(.activation, active: .appleIntelligence), .read(includeQuota: false),
                       "the inactive row's Set as Active gate still needs the availability")
    }

    func testTheSlowPollReadsOnlyTheAvailabilityAndOnlyWhenActive() {
        XCTAssertEqual(decide(.slowPoll), .read(includeQuota: false))
        XCTAssertEqual(decide(.slowPoll, active: .openAICompatible), .keep)
    }

    func testAfterARequestBothFactsAreReadWhenActive() {
        XCTAssertEqual(decide(.afterRequest), .read(includeQuota: true))
        XCTAssertEqual(decide(.afterRequest, active: .appleIntelligence), .keep)
    }

    func testTheSettingsOverloadReadsTheSameFields() {
        var settings = AIEndpointSettings(isEnabled: true)
        settings.configurations = [pcc]
        settings.apply(configuration: pcc)
        XCTAssertEqual(
            PrivateCloudComputeQueryPolicy.decide(trigger: .slowPoll, staticRefusal: nil, settings: settings),
            .read(includeQuota: false)
        )
        settings.isEnabled = false
        XCTAssertEqual(PrivateCloudComputeQueryPolicy.decide(trigger: .slowPoll, staticRefusal: nil, settings: settings), .clear)
    }
}
