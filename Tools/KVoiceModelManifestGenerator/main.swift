import Foundation
import KvoiceModelManagement

struct UsageError: Error {}

func usage() {
    fputs(
        """
        Usage: KVoiceModelManifestGenerator <prepared-package-directory> <manifest-output.json> [--release <model-id>]

          Without --release the package is the Whisper large-v3-turbo uncompressed
          release laid out as model/ + tokenizer/ (the original contract).
          With --release <model-id> the configuration comes from PinnedModelReleases;
          FluidAudio releases (ADR-019) are laid out as one model/ folder holding the
          Core ML bundles and the vocabulary JSON, e.g.
            --release parakeet-tdt-0.6b-v3-coreml
            --release parakeet-unified-en-0.6b-coreml
            --release nemotron-3.5-asr-streaming-multilingual-0.6b-coreml
            --release sensevoice-small-coreml
            --release paraformer-large-zh-coreml
            --release parakeet-realtime-eou-120m-coreml

        """,
        stderr
    )
}

do {
    var arguments = Array(CommandLine.arguments.dropFirst())
    var releaseID: String?
    if let index = arguments.firstIndex(of: "--release") {
        guard index + 1 < arguments.count else {
            usage()
            throw UsageError()
        }
        releaseID = arguments[index + 1]
        arguments.removeSubrange(index...(index + 1))
    }
    guard arguments.count == 2 else {
        usage()
        throw UsageError()
    }
    let packageURL = URL(fileURLWithPath: arguments[0], isDirectory: true)
    let outputURL = URL(fileURLWithPath: arguments[1])
    let configuration: ModelManifestGeneratorConfiguration
    if let releaseID {
        guard let fluidAudio = ModelManifestGeneratorConfiguration.fluidAudio(modelID: releaseID) else {
            fputs("unknown FluidAudio release: \(releaseID)\n", stderr)
            usage()
            throw UsageError()
        }
        configuration = fluidAudio
    } else {
        configuration = ModelManifestGeneratorConfiguration()
    }
    let generator = ModelManifestGenerator()
    let manifest = try generator.generate(packageURL: packageURL, configuration: configuration)
    let digest = try generator.write(manifest: manifest, to: outputURL)
    let totalBytes = manifest.files.reduce(Int64(0)) { $0 + $1.bytes }
    print("wrote " + outputURL.path)
    print("files=\(manifest.files.count) downloadBytes=\(totalBytes)")
    print("manifestSHA256=" + digest)
} catch {
    fputs("manifest generation failed: \(error.localizedDescription)\n", stderr)
    Foundation.exit(EXIT_FAILURE)
}
