import Foundation

/// The one model package supported by kvoice v1.
///
/// This value is deliberately kept in one place so a download URL, package
/// path, and runtime manifest cannot silently drift to a different model or
/// revision.
public enum KvoiceManagedModel {
    public static let modelID = "whisper-large-v3-turbo-coreml-uncompressed"
    public static let family = "whisper-large-v3-turbo"
    public static let format = "whisperkit-coreml"
    public static let repository = "argmaxinc/whisperkit-coreml"
    public static let revision = "04e5c42d80a522518023727e8c7e68d4bb391b28"
    public static let subdirectory = "openai_whisper-large-v3-v20240930_turbo"
    /// The tokenizer tree is not published alongside the CoreML package; it
    /// comes from the upstream Whisper repository at a pinned commit whose
    /// files hash to the manifest's tokenizer entries.
    public static let tokenizerRepository = "openai/whisper-large-v3"
    public static let tokenizerRevision = "06f233fe06e710322aca913c1bc4249a0d71fce1"
    public static let runtimePackage = "argmaxinc/argmax-oss-swift/WhisperKit"
    public static let runtimeVersion = "1.1.0"
    public static let defaultDownloadHost = URL(string: "https://huggingface.co")!
}
