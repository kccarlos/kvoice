// swift-tools-version: 6.2
// 6.2 (not 6.0) only so the FluidAudio dependency can be declared with
// `traits: []`, which leaves its optional NemoTextProcessing binary target
// unlinked (ADR-019). Nothing else in this manifest needs it.

import Foundation
import PackageDescription

let package = Package(
    name: "kvoice",
    // Required by SwiftPM for localized resources (the String Catalogs in
    // KvoiceUI). English is the source language of every catalog.
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "KvoiceDomain", targets: ["KvoiceDomain"]),
        .library(name: "KvoiceAppCore", targets: ["KvoiceAppCore"]),
        .library(name: "KvoiceTestSupport", targets: ["KvoiceTestSupport"]),
        .library(name: "KvoiceDiagnostics", targets: ["KvoiceDiagnostics"]),
        .library(name: "KvoiceTranscription", targets: ["KvoiceTranscription"]),
        .executable(name: "KVoiceBench", targets: ["KVoiceBench"]),
        .library(name: "KvoiceInsertion", targets: ["KvoiceInsertion"]),
        .library(name: "KvoiceHotkeys", targets: ["KvoiceHotkeys"]),
        .library(name: "KvoiceUI", targets: ["KvoiceUI"]),
        .library(name: "KvoiceAudio", targets: ["KvoiceAudio"]),
        .library(name: "KvoicePersistence", targets: ["KvoicePersistence"]),
        .library(name: "KvoiceAI", targets: ["KvoiceAI"]),
        .library(name: "KvoiceModelManagement", targets: ["KvoiceModelManagement"]),
        .library(name: "KvoiceParakeet", targets: ["KvoiceParakeet"]),
        .library(name: "KvoiceAppleIntelligence", targets: ["KvoiceAppleIntelligence"]),
        .library(name: "KvoiceAppleSpeech", targets: ["KvoiceAppleSpeech"]),
        .executable(name: "KVoiceModelManifestGenerator", targets: ["KVoiceModelManifestGenerator"])
    ],
    dependencies: [
        // Exact pins are part of the architecture contract. Feature adapters
        // import these products only from their owning workstream targets.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", exact: "3.0.1"),
        // ADR-019: the Parakeet runtime. Apache-2.0, no transitive Swift
        // packages. `traits: []` opts out of its NemoTextProcessing binary
        // xcframework (TTS text normalisation kvoice never calls), so no
        // prebuilt third-party binary enters the build.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.7", traits: [])
    ],
    targets: [
        .target(
            name: "KvoiceDomain",
            path: "Packages/KvoiceDomain/Sources/KvoiceDomain",
            resources: [.process("Resources")]
        ),
        .target(
            name: "KvoiceAppCore",
            dependencies: ["KvoiceDomain"],
            path: "Packages/KvoiceAppCore/Sources/KvoiceAppCore"
        ),
        .target(
            name: "KvoiceTestSupport",
            dependencies: ["KvoiceDomain"],
            path: "Packages/KvoiceTestSupport/Sources/KvoiceTestSupport"
        ),
        .target(
            name: "KvoiceDiagnostics",
            dependencies: ["KvoiceDomain"],
            path: "Packages/KvoiceDiagnostics/Sources/KvoiceDiagnostics"
        ),
        .target(
            name: "KvoiceTranscription",
            dependencies: [
                "KvoiceDomain",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "ArgmaxOSS", package: "argmax-oss-swift")
            ],
            path: "Packages/KvoiceTranscription/Sources/KvoiceTranscription",
            // The Runtime card's performance-test clip (see
            // PerformanceSampleAudio.swift for provenance). Copied so the
            // file keeps its name in the resource bundle.
            resources: [.copy("Resources/PerformanceSample.wav")]
        ),
        .executableTarget(
            name: "KVoiceBench",
            dependencies: ["KvoiceDomain", "KvoiceTranscription"],
            path: "Tools/KVoiceBench/Sources/KVoiceBench/RuntimeSpike"
        ),
        .target(
            name: "KvoiceInsertion",
            dependencies: ["KvoiceDomain"],
            path: "Packages/KvoiceInsertion/Sources/KvoiceInsertion"
        ),
        .target(
            name: "KvoiceHotkeys",
            dependencies: [
                "KvoiceDomain",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
            path: "Packages/KvoiceHotkeys/Sources/KvoiceHotkeys"
        ),
        .target(
            name: "KvoicePersistence",
            dependencies: ["KvoiceDomain"],
            path: "Packages/KvoicePersistence/Sources/KvoicePersistence",
            // System SQLite for the history database (ADR-011). No third-party
            // wrapper; the C API is used directly through one actor.
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "KvoiceAI",
            dependencies: ["KvoiceDomain"],
            path: "Packages/KvoiceAI/Sources/KvoiceAI"
        ),
        .target(
            name: "KvoiceModelManagement",
            dependencies: ["KvoiceDomain", "KvoiceTranscription"],
            path: "Packages/KvoiceModelManagement/Sources/KvoiceModelManagement",
            // ADR-017: the bundled speech-model catalog and one trusted
            // manifest per entry. Copied, not processed, so the Manifests
            // folder keeps its layout in the resource bundle.
            resources: [
                .copy("Resources/SpeechModelCatalog.json"),
                .copy("Resources/Manifests")
            ]
        ),
        .target(
            name: "KvoiceParakeet",
            // ADR-019: the only target allowed to import FluidAudio, and there
            // only `FluidAudioParakeetRuntime.swift` does (a test scans for
            // it). KvoiceTranscription supplies the trust-anchor type and the
            // canonical manifest digest; no WhisperKit type is used.
            dependencies: [
                "KvoiceDomain",
                "KvoiceTranscription",
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Packages/KvoiceParakeet/Sources/KvoiceParakeet"
        ),
        .target(
            name: "KvoiceAppleIntelligence",
            // ADR-024: the only target allowed to import FoundationModels, and
            // there only `FoundationModelsRuntime.swift` does (a test scans
            // for it). Depends on KvoiceDomain alone; no URLSession, no
            // network I/O. The framework exists from macOS 26 and the
            // deployment target is 15, so it is linked weakly: every use is
            // behind `#available(macOS 26, *)`, and on an older system the
            // missing framework is never touched.
            dependencies: ["KvoiceDomain"],
            path: "Packages/KvoiceAppleIntelligence/Sources/KvoiceAppleIntelligence",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"])]
        ),
        .target(
            name: "KvoiceAppleSpeech",
            // ADR-025: the only target allowed to import Speech, and there
            // only `SpeechFrameworkRuntime.swift` does (a test scans for it).
            // Depends on KvoiceDomain alone; no URLSession, no network I/O
            // of its own (the asset download is the OS's). The framework
            // exists on macOS 15 (the old SFSpeechRecognizer API) but the
            // `SpeechAnalyzer` symbols kvoice uses arrive with macOS 26, so
            // every use is behind `#available(macOS 26, *)` and the framework
            // is linked weakly like FoundationModels, so an older system
            // never resolves a symbol it does not have.
            dependencies: ["KvoiceDomain"],
            path: "Packages/KvoiceAppleSpeech/Sources/KvoiceAppleSpeech",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "Speech"])]
        ),
        .executableTarget(
            name: "KVoiceModelManifestGenerator",
            dependencies: ["KvoiceModelManagement"],
            path: "Tools/KVoiceModelManifestGenerator",
            exclude: ["README.md"]
        ),
        .target(
            name: "KvoiceUI",
            // KvoiceAI supplies the endpoint URL rules so the AI settings screen
            // rejects a credential-bearing or insecure URL before persisting it,
            // with one implementation of the rule rather than two. KvoiceAppCore
            // supplies `SettingsCoordinator` / `SettingsIntent` (ADR-022 slice
            // 7): the settings view models are projections over the coordinator
            // and write through intents, never through a copy of their own.
            dependencies: ["KvoiceDomain", "KvoiceAI", "KvoiceAppCore"],
            path: "Packages/KvoiceUI/Sources/KvoiceUI",
            // String Catalogs (Localizable.xcstrings for KvoiceUI's own copy,
            // DomainCopy.xcstrings for KvoiceDomain's user-facing sentences).
            // Processed so SwiftPM compiles them into <lang>.lproj inside
            // Bundle.module. See Docs/Localization.md.
            resources: [.process("Resources")]
        ),
        .target(
            name: "KvoiceAudio",
            dependencies: ["KvoiceDomain"],
            path: "Packages/KvoiceAudio/Sources/KvoiceAudio"
        ),
        .testTarget(
            name: "KvoiceDomainTests",
            dependencies: ["KvoiceDomain"],
            path: "Packages/KvoiceDomain/Tests/KvoiceDomainTests"
        ),
        .testTarget(
            name: "KvoiceAppCoreTests",
            // KvoiceAI only for AIProviderRoutingClientTests: the real
            // endpoint client's URL rules must surface through the router.
            dependencies: ["KvoiceAppCore", "KvoiceTestSupport", "KvoiceAI"],
            path: "Packages/KvoiceAppCore/Tests/KvoiceAppCoreTests"
        ),
        .testTarget(
            name: "KvoiceDiagnosticsTests",
            dependencies: ["KvoiceDiagnostics"],
            path: "Packages/KvoiceDiagnostics/Tests/KvoiceDiagnosticsTests"
        ),
        .testTarget(
            name: "KvoiceTranscriptionTests",
            dependencies: ["KvoiceTranscription", "KvoiceDomain"],
            path: "Packages/KvoiceTranscription/Tests/KvoiceTranscriptionTests"
        ),
        .testTarget(
            name: "KvoiceInsertionTests",
            dependencies: ["KvoiceInsertion", "KvoiceDomain", "KvoiceTestSupport"],
            path: "Packages/KvoiceInsertion/Tests/KvoiceInsertionTests"
        ),
        .testTarget(
            name: "KvoiceHotkeysTests",
            dependencies: ["KvoiceHotkeys", "KvoiceDomain"],
            path: "Packages/KvoiceHotkeys/Tests/KvoiceHotkeysTests"
        ),
        .testTarget(
            name: "KvoicePersistenceTests",
            dependencies: ["KvoicePersistence", "KvoiceDomain"],
            path: "Packages/KvoicePersistence/Tests/KvoicePersistenceTests"
        ),
        .testTarget(
            name: "KvoiceAITests",
            dependencies: ["KvoiceAI", "KvoiceDomain"],
            path: "Packages/KvoiceAI/Tests/KvoiceAITests"
        ),
        .testTarget(
            name: "KvoiceModelManagementTests",
            dependencies: ["KvoiceModelManagement", "KvoiceDomain", "KvoiceTranscription", "KvoiceTestSupport"],
            path: "Packages/KvoiceModelManagement/Tests/KvoiceModelManagementTests"
        ),
        .testTarget(
            name: "KvoiceParakeetTests",
            dependencies: ["KvoiceParakeet", "KvoiceDomain", "KvoiceTranscription", "KvoiceModelManagement"],
            path: "Packages/KvoiceParakeet/Tests/KvoiceParakeetTests"
        ),
        .testTarget(
            name: "KvoiceAppleIntelligenceTests",
            dependencies: ["KvoiceAppleIntelligence", "KvoiceDomain"],
            path: "Packages/KvoiceAppleIntelligence/Tests/KvoiceAppleIntelligenceTests"
        ),
        .testTarget(
            name: "KvoiceAppleSpeechTests",
            // KvoiceTranscription only for the live check's bundled sample
            // (`PerformanceSampleAudio`); the hermetic tests use the fake.
            dependencies: ["KvoiceAppleSpeech", "KvoiceDomain", "KvoiceTranscription", "KvoiceTestSupport"],
            path: "Packages/KvoiceAppleSpeech/Tests/KvoiceAppleSpeechTests"
        ),
        .testTarget(
            name: "KvoiceUITests",
            // KvoiceAppCore only for DomainCopyTests, which checks that its
            // user-facing sentences have translations in KvoiceUI's catalog;
            // KvoiceTestSupport for `ParkingClock`, which drives the view
            // models' timers without real sleeps.
            dependencies: ["KvoiceUI", "KvoiceDomain", "KvoiceAppCore", "KvoiceTestSupport"],
            path: "Packages/KvoiceUI/Tests/KvoiceUITests"
        ),
        .testTarget(
            name: "KvoiceAudioTests",
            dependencies: ["KvoiceAudio", "KvoiceDomain"],
            path: "Packages/KvoiceAudio/Tests/KvoiceAudioTests"
        )
    ],
    swiftLanguageModes: [.v6]
)

// The archived validation spikes (Tools/Spikes, see Tools/README.md) are
// built only where they exist. They are development evidence and the public
// export leaves them out (Docs/Repositories.md), so the same manifest has to
// resolve in both trees without an edit.
if FileManager.default.fileExists(atPath: Context.packageDirectory + "/Tools/Spikes") {
    package.products += [
        .executable(name: "AXTextEditSpike", targets: ["AXTextEditSpike"]),
        .executable(name: "KVoiceAudioSpike", targets: ["KVoiceAudioSpike"])
    ]
    package.targets += [
        .executableTarget(
            name: "AXTextEditSpike",
            dependencies: ["KvoiceInsertion", "KvoiceDomain"],
            path: "Tools/Spikes/AXTextEditSpike",
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "KVoiceAudioSpike",
            dependencies: ["KvoiceAudio", "KvoiceDomain"],
            path: "Tools/Spikes/KVoiceAudioSpike"
        )
    ]
}
