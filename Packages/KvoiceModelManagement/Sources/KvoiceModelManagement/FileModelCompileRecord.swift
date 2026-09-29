import Foundation
import KvoiceDomain

/// `ModelCompileRecording` as one small JSON file beside the models
/// (`<storage>/model-compile-record.json`): the macOS build and the Mac
/// model (`hw.model`) it was written under, and the `ModelCompileKey.token`s
/// compiled since. A file from another build or another Mac reads as empty
/// — an OS update replaces the Neural Engine compiler, and a migrated home
/// folder has compiled nothing on the new hardware.
///
/// Machine-local on purpose: it is not a setting, not in `AppSettings` or
/// the settings backup, and it is excluded from Time Machine
/// (`isExcludedFromBackup`), so a restore onto another Mac cannot claim
/// that Mac has compiled anything. A missing or unreadable file is "nothing
/// compiled" (the worst case is one "first time" line too many); a failed
/// write is ignored for the same reason.
public actor FileModelCompileRecord: ModelCompileRecording {
    struct Contents: Codable, Equatable {
        var systemBuild: String
        var hardwareModel: String?
        var compiled: [String]
    }

    public static let fileName = "model-compile-record.json"

    private let fileURL: URL
    private let systemBuild: String
    private let hardwareModel: String
    private var cached: Contents?

    /// - Parameters:
    ///   - directoryURL: the model storage directory
    ///     (`ModelPackageManager.defaultStorageDirectoryURL()`).
    ///   - systemBuild: the running OS's version string, e.g.
    ///     `ProcessInfo.processInfo.operatingSystemVersionString`
    ///     ("Version 27.0 (Build 27A…)"); injected so tests pin it.
    ///   - hardwareModel: the Mac model (`currentHardwareModel()`, e.g.
    ///     "Mac16,1"); injected so tests pin it.
    public init(directoryURL: URL, systemBuild: String, hardwareModel: String) {
        fileURL = directoryURL.appendingPathComponent(Self.fileName, isDirectory: false)
        self.systemBuild = systemBuild
        self.hardwareModel = hardwareModel
    }

    /// `sysctl hw.model`, or "unknown".
    public static func currentHardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public func hasCompiled(_ key: ModelCompileKey) -> Bool {
        contents().compiled.contains(key.token)
    }

    public func recordCompiled(_ key: ModelCompileKey) {
        var current = contents()
        guard !current.compiled.contains(key.token) else { return }
        current.compiled.append(key.token)
        current.compiled.sort()
        cached = current
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(current) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
        // An atomic write replaces the file, so the flag is set every time.
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private func contents() -> Contents {
        if let cached { return cached }
        let empty = Contents(systemBuild: systemBuild, hardwareModel: hardwareModel, compiled: [])
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Contents.self, from: data),
              decoded.systemBuild == systemBuild,
              decoded.hardwareModel == hardwareModel else {
            cached = empty
            return empty
        }
        cached = decoded
        return decoded
    }
}
