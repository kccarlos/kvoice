import Foundation
import Darwin
import KvoiceDomain
import KvoiceTranscription

/// Small command-line entry point for the T-01/T-02 harness. It accepts only a
/// verified local package and external corpus directory; model acquisition is
/// intentionally not a command-line responsibility.
@main
struct KVoiceBench {
    static func main() async {
        do {
            let command = try RuntimeSpikeArguments(arguments: Array(CommandLine.arguments.dropFirst()))
            let runner = try RuntimeSpikeRunner(
                manifestURL: command.manifestURL,
                audioDirectory: command.audioDirectory
            )
            let package = try loadPackage(at: command.modelPackageURL)
            let trustAnchor = try WhisperModelReleaseTrustAnchor(
                manifestData: Data(contentsOf: command.trustedReleaseManifestURL),
                manifestSHA256: command.trustedReleaseManifestSHA256
            )
            let run = try await runner.run(
                engine: WhisperTranscriptionEngine(trustedReleases: [trustAnchor]),
                package: package,
                iterations: command.iterations,
                stabilityJobs: command.stabilityJobs
            )
            let outputDirectory = command.outputURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(run).write(to: command.outputURL, options: .atomic)
            print("PASS: \(run.measurements.count) measurements written to \(command.outputURL.path)")
        } catch {
            fputs("KVoiceBench: \(error.localizedDescription)\n\(RuntimeSpikeArguments.usage)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func loadPackage(at url: URL) throws -> InstalledModelPackage {
        let manifest = try loadManifest(at: url.appendingPathComponent("ModelManifest.json"))
        return InstalledModelPackage(
            manifest: manifest,
            packageURL: url.standardizedFileURL,
            modelFolderURL: url.appendingPathComponent("model", isDirectory: true),
            tokenizerFolderURL: url.appendingPathComponent("tokenizer", isDirectory: true),
            ownership: .managedByKvoice
        )
    }

    private static func loadManifest(at url: URL) throws -> ModelManifest {
        try JSONDecoder().decode(
            ModelManifest.self,
            from: Data(contentsOf: url)
        )
    }
}

private struct RuntimeSpikeArguments {
    let manifestURL: URL
    let audioDirectory: URL
    let modelPackageURL: URL
    let trustedReleaseManifestURL: URL
    let trustedReleaseManifestSHA256: String
    let iterations: Int
    let stabilityJobs: Int
    let outputURL: URL

    static let usage = """
    Usage:
      KVoiceBench run --manifest <corpus.json> --model-package <verified-package> \
        --audio-directory <external-audio> --trusted-release-manifest <manifest.json> \
        --trusted-release-digest <sha256> --iterations <n> \
        [--stability-jobs <n>] --output <result.json>

    The package must contain ModelManifest.json, model/, and tokenizer/. The
    trusted release manifest and digest must come from app-owned release
    evidence, not the installed package. The model package and external audio
    directory are read-only inputs. Run results contain output hashes and
    comparator metadata, not transcript text, reference text, protected-span
    values, or copied audio. Stability defaults to 50 sequential jobs.
    """

    init(arguments: [String]) throws {
        guard arguments.first == "run" else {
            throw RuntimeSpikeError.invalidManifest("missing 'run' command")
        }
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            guard flag.hasPrefix("--"), index + 1 < arguments.count else {
                throw RuntimeSpikeError.invalidManifest("expected flag/value pair")
            }
            values[flag] = arguments[index + 1]
            index += 2
        }

        guard let manifest = values["--manifest"],
              let modelPackage = values["--model-package"],
              let rawAudioDirectory = values["--audio-directory"],
              let trustedReleaseManifest = values["--trusted-release-manifest"],
              let trustedReleaseDigest = values["--trusted-release-digest"],
              let output = values["--output"] else {
            throw RuntimeSpikeError.invalidManifest("required run arguments are missing")
        }
        let iterationValue = values["--iterations"] ?? "1"
        guard let iterations = Int(iterationValue), iterations > 0 else {
            throw RuntimeSpikeError.unsupportedIterationCount
        }
        let stabilityValue = values["--stability-jobs"] ?? "50"
        guard let stabilityJobs = Int(stabilityValue), stabilityJobs >= 0 else {
            throw RuntimeSpikeError.unsupportedStabilityJobCount
        }
        if let mode = values["--mode"], mode != "warm" {
            throw RuntimeSpikeError.invalidManifest("only --mode warm is implemented by T-01/T-02")
        }

        manifestURL = URL(fileURLWithPath: manifest)
        audioDirectory = URL(fileURLWithPath: rawAudioDirectory)
        modelPackageURL = URL(fileURLWithPath: modelPackage)
        trustedReleaseManifestURL = URL(fileURLWithPath: trustedReleaseManifest)
        trustedReleaseManifestSHA256 = trustedReleaseDigest
        self.iterations = iterations
        self.stabilityJobs = stabilityJobs
        outputURL = URL(fileURLWithPath: output)
    }
}
