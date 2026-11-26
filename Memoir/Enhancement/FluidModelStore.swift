@preconcurrency import CoreML
import FluidAudio
import Foundation
import OSLog
import Synchronization

nonisolated enum OptionalModelError: LocalizedError {
    case alreadyInstalling(OptionalModel)
    case incompleteDownload(OptionalModel)
    case inUse(OptionalModel)
    case running(OptionalModel)
    case notInstalled(OptionalModel)

    var errorDescription: String? {
        switch self {
        case .alreadyInstalling(let model):
            "The \(model.displayName) is already being downloaded."
        case .incompleteDownload(let model):
            "The \(model.displayName) did not download completely. Try again."
        case .inUse(let model):
            "The \(model.displayName) is being downloaded and cannot be removed right now."
        case .running(let model):
            "The \(model.displayName) is working on a recording and cannot be removed right now."
        case .notInstalled(let model):
            "The \(model.displayName) is not installed. Download it in Settings first."
        }
    }
}

extension OptionalModel {
    nonisolated var displayName: String {
        switch self {
        case .speakerIdentification: "speaker identification model"
        case .enhancedTranscription: "enhanced transcription model"
        }
    }
}

/// Downloads the optional models into Memoir's own folder and keeps track of which ones are
/// complete.
nonisolated struct FluidModelStore: OptionalModelManaging {
    let directory: URL

    init(directory: URL = FluidModels.directory) {
        self.directory = directory
        FluidNetwork.stayOffline()
    }

    func isInstalled(_ model: OptionalModel) async -> Bool {
        FluidModels.isInstalled(model, in: directory)
    }

    func installedSize(of model: OptionalModel) async -> Int64? {
        guard FluidModels.isInstalled(model, in: directory) else { return nil }
        return FluidModels.size(of: FluidModels.folder(for: model, in: directory))
    }

    /// The last install of each model. Cancelling one only asks FluidAudio's download to stop,
    /// and until it does the model stays locked, so the next install or removal waits for it
    /// rather than failing.
    private static let installs = Mutex<[OptionalModel: Task<Void, Never>]>([:])

    func install(_ model: OptionalModel) -> AsyncThrowingStream<Double, Error> {
        let directory = directory
        return AsyncThrowingStream { continuation in
            let task = Self.installs.withLock { installs in
                let previous = installs[model]
                let task = Task {
                    await previous?.value
                    do {
                        try Task.checkCancellation()
                        try await FluidModels.install(model, in: directory) { continuation.yield($0) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                installs[model] = task
                return task
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func remove(_ model: OptionalModel) async throws {
        // Only a cancelled install is waited for. One still running fails the removal, since
        // waiting would mean sitting out the whole download.
        if let install = Self.installs.withLock({ $0[model] }), install.isCancelled {
            await install.value
        }
        try FluidModels.whileIdle(model, in: directory) {
            let folder = FluidModels.folder(for: model, in: directory)
            guard FileManager.default.fileExists(atPath: folder.path) else { return }
            try FileManager.default.removeItem(at: folder)
        }
    }
}

/// Everything that knows where and how FluidAudio's models are stored. Shared by the store and
/// the enhancer, which must agree on what "installed" means.
nonisolated enum FluidModels {
    static let log = Logger(subsystem: "de.jandow.Memoir", category: "OptionalModels")

    /// Ultra is a post-training of Parakeet TDT v3 with the same languages and decoder contract,
    /// more accurate on every benchmark FluidAudio publishes at the same speed, and like v3
    /// licensed CC-BY-4.0.
    static let transcriptionVersion: AsrModelVersion = .ultra
    static let transcriptionRepo: Repo = .parakeetUltra
    static let diarizerRepo: Repo = .diarizer
    /// Selects the pyannote Community-1 files of the diarizer repo, not the older online models.
    static let diarizerVariant = "offline"

    /// Not FluidAudio's default folder, so removing Memoir's data removes the models too and
    /// Debug builds keep their own copy.
    static var directory: URL {
        RecordingFiles.baseDirectory.appending(path: "Models", directoryHint: .isDirectory)
    }

    static func folder(for model: OptionalModel, in directory: URL) -> URL {
        directory.appending(path: repo(for: model).folderName, directoryHint: .isDirectory)
    }

    private static func repo(for model: OptionalModel) -> Repo {
        switch model {
        case .speakerIdentification: diarizerRepo
        case .enhancedTranscription: transcriptionRepo
        }
    }

    // MARK: - Completeness

    /// Written last, after the files were downloaded and loaded once. FluidAudio resumes
    /// interrupted downloads in place, so a folder without it may hold half a model.
    private static let markerName = ".memoir-installed"

    static func isInstalled(_ model: OptionalModel, in directory: URL) -> Bool {
        let folder = folder(for: model, in: directory)
        guard FileManager.default.fileExists(atPath: folder.appending(path: markerName).path) else { return false }
        return hasCompleteFiles(model, in: directory)
    }

    /// The same check FluidAudio makes before it trusts its cache: every compiled model has
    /// its root `coremldata.bin` and no `.partial` file left from an interrupted download.
    static func hasCompleteFiles(_ model: OptionalModel, in directory: URL) -> Bool {
        let folder = folder(for: model, in: directory)
        switch model {
        case .enhancedTranscription:
            return AsrModels.modelsExist(at: folder, version: transcriptionVersion)
        case .speakerIdentification:
            let fileManager = FileManager.default
            let bundles = [
                ModelNames.OfflineDiarizer.segmentationPath, ModelNames.OfflineDiarizer.fbankPath,
                ModelNames.OfflineDiarizer.embeddingPath, ModelNames.OfflineDiarizer.pldaRhoPath,
            ]
            for bundle in bundles {
                let url = folder.appending(path: bundle, directoryHint: .isDirectory)
                guard fileManager.fileExists(atPath: url.appending(path: "coremldata.bin").path),
                      !containsPartialDownload(url)
                else { return false }
            }
            return fileManager.fileExists(atPath: folder.appending(path: ModelNames.OfflineDiarizer.pldaParameters).path)
        }
    }

    private static func containsPartialDownload(_ url: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return false }
        for case let item as URL in enumerator where item.pathExtension == "partial" {
            return true
        }
        return false
    }

    static func size(of folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: - Install

    /// What each model folder is busy with. One lock for both, so a removal can't slip in between
    /// an enhancement checking that a model is installed and starting to use it. Keyed by folder,
    /// not model, so a copy in a test's temporary directory isn't blocked by the real one.
    private struct Activity {
        var installing: Set<String> = []
        var running: [String: Int] = [:]
    }

    private static func activityKey(_ model: OptionalModel, in directory: URL) -> String {
        folder(for: model, in: directory).standardizedFileURL.path
    }

    private static let activity = Mutex(Activity())

    /// Share of the progress bar for the download. The rest is the first load, which compiles
    /// the models for this Mac's Neural Engine and takes a noticeable while for the encoder.
    private static let downloadShare = 0.85

    static func install(
        _ model: OptionalModel,
        in directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let key = activityKey(model, in: directory)
        guard activity.withLock({ $0.installing.insert(key).inserted }) else {
            throw OptionalModelError.alreadyInstalling(model)
        }
        defer { _ = activity.withLock { $0.installing.remove(key) } }

        if isInstalled(model, in: directory) {
            progress(1)
            return
        }
        let folder = folder(for: model, in: directory)
        try? FileManager.default.removeItem(at: folder.appending(path: markerName))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // FluidAudio reports the download as 0...0.5 of a download-and-compile operation; the
        // compile half never comes from `download`, so the bar is rescaled. It reports every
        // few kilobytes, tens of thousands of times for the transcription model, so only steps
        // a progress bar can show are passed on.
        let highest = Mutex(0.0)
        let report: ProgressHandler = { update in
            let fraction = min(max(update.fractionCompleted * 2, 0), 1) * downloadShare
            let value = highest.withLock { current -> Double? in
                guard fraction >= current + 0.002 else { return nil }
                current = fraction
                return fraction
            }
            if let value { progress(value) }
        }

        let began = ContinuousClock.now
        try await FluidNetwork.whileDownloading {
            switch model {
            case .enhancedTranscription:
                // The vocabulary is a plain file at the repo root; naming it makes the download
                // fail loudly instead of finishing without it.
                try await ModelHub.download(
                    transcriptionRepo, to: directory,
                    additionalModelNames: [ModelNames.ASR.vocabularyFile],
                    progressHandler: report)
            case .speakerIdentification:
                try await ModelHub.download(diarizerRepo, to: directory, variant: diarizerVariant, progressHandler: report)
            }
        }
        try Task.checkCancellation()
        guard hasCompleteFiles(model, in: directory) else { throw OptionalModelError.incompleteDownload(model) }
        let downloaded = ContinuousClock.now
        progress(downloadShare)

        // Loading once here moves the slow first compile out of the first enhancement.
        switch model {
        case .enhancedTranscription:
            _ = try loadTranscription(from: directory)
        case .speakerIdentification:
            _ = try loadDiarizer(from: directory)
        }
        try Task.checkCancellation()
        try Data().write(to: folder.appending(path: markerName))
        log.info("Installed \(model.rawValue, privacy: .public): download \(downloaded - began), first load \(ContinuousClock.now - downloaded), \(size(of: folder)) bytes")
        progress(1)
    }

    /// Runs `body` while nothing downloads or uses `model`, holding that state until it returns.
    static func whileIdle<T>(_ model: OptionalModel, in directory: URL, _ body: () throws -> T) throws -> T {
        let key = activityKey(model, in: directory)
        return try activity.withLock { activity in
            guard !activity.installing.contains(key) else { throw OptionalModelError.inUse(model) }
            guard activity.running[key, default: 0] == 0 else { throw OptionalModelError.running(model) }
            return try body()
        }
    }

    /// Keeps `models` from being removed while `body` runs. Throws `modelMissing` for the first
    /// one that is not installed.
    static func whileRunning<T>(
        _ models: [OptionalModel],
        in directory: URL,
        _ body: () async throws -> T
    ) async throws -> T {
        let keys = models.map { activityKey($0, in: directory) }
        try activity.withLock { activity in
            if let missing = models.first(where: { !isInstalled($0, in: directory) }) {
                throw EnhancementError.modelMissing(missing)
            }
            for key in keys { activity.running[key, default: 0] += 1 }
        }
        defer {
            activity.withLock { activity in
                for key in keys { activity.running[key, default: 1] -= 1 }
            }
        }
        return try await body()
    }

    // MARK: - Loading

    // Both loaders read only the files on disk. FluidAudio's own loaders download whatever is
    // missing and, when a load fails, delete the cache and download it again, which must
    // never happen outside `install`.

    static func loadTranscription(from directory: URL) throws -> AsrModels {
        try AsrModels.loadLocal(
            from: folder(for: .enhancedTranscription, in: directory), version: transcriptionVersion)
    }

    /// Mirrors `OfflineDiarizerModels.load`: segmentation, embedding and PLDA on all compute
    /// units, FBank on the CPU where FluidAudio measured it fastest.
    static func loadDiarizer(from directory: URL) throws -> OfflineDiarizerModels {
        let folder = folder(for: .speakerIdentification, in: directory)
        let began = Date()
        func model(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            return try MLModel(contentsOf: folder.appending(path: name, directoryHint: .isDirectory), configuration: configuration)
        }
        let names = ModelNames.OfflineDiarizer.self
        return OfflineDiarizerModels(
            segmentationModel: try model(names.segmentationPath, .all),
            fbankModel: try model(names.fbankPath, .cpuOnly),
            embeddingModel: try model(names.embeddingPath, .all),
            pldaRhoModel: try model(names.pldaRhoPath, .all),
            pldaPsi: try pldaPsi(at: folder.appending(path: names.pldaParameters)),
            compilationDuration: Date().timeIntervalSince(began)
        )
    }

    /// The PLDA eigenvalues, stored as base64 float32 in `tensors.psi.data_base64`. FluidAudio
    /// reads them the same way but keeps that reader private.
    static func pldaPsi(at url: URL) throws -> [Double] {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        guard let tensors = root?["tensors"] as? [String: Any],
              let psi = tensors["psi"] as? [String: Any],
              let base64 = psi["data_base64"] as? String,
              let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]),
              data.count >= MemoryLayout<Float>.size
        else { throw OptionalModelError.incompleteDownload(.speakerIdentification) }
        var floats = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return floats.map(Double.init)
    }
}

/// FluidAudio's offline switch, `ModelHub.offlineMode`, is one process-wide flag with no
/// synchronization of its own. Memoir keeps it on except while an install is downloading, so
/// any FluidAudio code path that would quietly fetch or re-fetch a model fails instead. The
/// enhancer does not rely on it: it only uses loaders that never touch the network.
nonisolated enum FluidNetwork {
    private static let downloads = Mutex(0)

    static func stayOffline() {
        downloads.withLock { count in
            if count == 0 { ModelHub.offlineMode = true }
        }
    }

    static func whileDownloading<T>(_ body: () async throws -> T) async throws -> T {
        downloads.withLock { count in
            count += 1
            ModelHub.offlineMode = false
        }
        defer {
            downloads.withLock { count in
                count -= 1
                if count == 0 { ModelHub.offlineMode = true }
            }
        }
        return try await body()
    }
}
