import CryptoKit
import Foundation
import Observation
import os

// MARK: - Layers: what the Scan4D server makes from a scan (REQ-041)

/// One layer of a scan as the control plane reports it in the sync reply (scan4d-server README,
/// "Layers"): a kind (`splat` for now), the latest version, its files, and where it sits. The server
/// makes it from the scan's bundle; the phone only downloads it, into the scan's folder, and never
/// sends it back: it is in no bundle and no export.
nonisolated struct ScanLayer: Codable, Equatable, Sendable {
    nonisolated struct Subject: Codable, Equatable, Sendable {
        let mapId: String?
        let scanId: String?
    }

    nonisolated struct File: Codable, Equatable, Sendable {
        let name: String
        /// Its quality level: `full`, or `light`, the same made small enough for a phone (`SplatQuality`).
        let role: String
        let bytes: Int64
        let sha256: String
        /// Its path on the server (`/v1/scans/{id}/layers/{kind}/{name}`); Range requests resume it.
        let url: String
    }

    /// 4x4 column-major matrices from the layer's own coordinates: into the scan's capture world,
    /// into its focus box's frame (focus scans), and into the map's canonical frame (when the scan
    /// is in it).
    nonisolated struct Placement: Codable, Equatable, Sendable {
        let toCapture: [Float]?
        let toBox: [Float]?
        let toCanonical: [Float]?
    }

    /// The kind's own fields. A splat: its full level's Gaussian count, SOG version and SH degree,
    /// and each level's own by role (`levels`, from servers since levels).
    nonisolated struct Meta: Codable, Equatable, Sendable {
        nonisolated struct Level: Codable, Equatable, Sendable {
            let count: Int?
        }

        let count: Int?
        let sogVersion: Int?
        let shDegree: Int?
        let levels: [String: Level]?
    }

    let kind: String
    let subject: Subject
    /// When it was published, UTC (20261115T142300Z): compared as a string, never parsed.
    let version: String
    /// `current`, or `stale`: made from an older version of the scan than the server holds now.
    let state: String
    let files: [File]
    let placement: Placement?
    let meta: Meta?
    /// The level of the file this phone holds, set when it is installed (`LayerCache.install`): nil
    /// in the server's reply, and in a copy from before levels, which holds the full file.
    var installedRole: String?

    static let splat = "splat"
    static let fullRole = "full"

    var scanId: UUID? { subject.scanId.flatMap(UUID.init(uuidString:)) }
    var isStale: Bool { state == "stale" }

    /// The file to download at `quality`: that level's, else the full one (a layer from before
    /// levels, or made with the full level only), else the layer's first.
    func file(for quality: SplatQuality) -> File? {
        files.first { $0.role == quality.rawValue } ?? files.first { $0.role == Self.fullRole } ?? files.first
    }

    /// The file a copy on this phone holds.
    var installedFile: File? {
        installedRole.flatMap { role in files.first { $0.role == role } } ?? file(for: .full)
    }

    /// The Gaussians in the file a copy on this phone holds: its level's count, else the full level's
    /// (a layer from before levels).
    var installedCount: Int? {
        installedFile.flatMap { meta?.levels?[$0.role]?.count } ?? meta?.count
    }
}

/// Which level of a splat layer this phone downloads (scan4d-server README, "Layers"), set in the
/// Server tab. Light, the default: the splat merged down to 250k Gaussians and retrained, a few MB,
/// which every phone draws. Full: every Gaussian the server trained, tens of MB. A layer without the
/// level asked for gives its full file.
nonisolated enum SplatQuality: String, CaseIterable, Sendable {
    case light
    case full

    var title: String {
        switch self {
        case .light: "Light"
        case .full: "Full"
        }
    }

    static var current: SplatQuality {
        UserDefaults.standard.string(forKey: AppConstants.Key.splatQuality).flatMap(SplatQuality.init(rawValue:))
            ?? AppConstants.splatQuality
    }
}

// MARK: - The copy on this phone

/// A scan's downloaded layers live in its own folder, `<scan>/layers/<kind>/`: the file and the
/// `layer.json` it came with, written last. Bundles and exports read named files of the scan, never
/// this folder, so a layer never goes back to the server; deleting the scan deletes it. The folder is
/// left out of iCloud backups: it can be downloaded again.
nonisolated enum LayerCache {
    static let folder = "layers"
    static let documentName = "layer.json"

    nonisolated struct ChangedOnServer: LocalizedError {
        var errorDescription: String? {
            "It changed on the server while it downloaded. Sync, then download it again."
        }
    }

    static func directory(scanDirectory: URL, kind: String) -> URL {
        scanDirectory.appendingPathComponent(folder).appendingPathComponent(kind)
    }

    /// The layer on disk, or nil. File I/O: call it off the main thread.
    static func local(scanDirectory: URL, kind: String) -> ScanLayer? {
        let url = directory(scanDirectory: scanDirectory, kind: kind).appendingPathComponent(documentName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ScanLayer.self, from: data)
    }

    /// The downloaded file, where a viewer opens it.
    static func fileURL(scanDirectory: URL, layer: ScanLayer) -> URL? {
        layer.installedFile.map { directory(scanDirectory: scanDirectory, kind: layer.kind).appendingPathComponent($0.name) }
    }

    /// Checks `downloaded` against the file's sha256, then swaps it in as the scan's copy of the
    /// layer, its `layer.json` written last: a reader finds the old copy or the new one, never half.
    /// The downloaded file is gone afterwards either way.
    static func install(_ downloaded: URL, file: ScanLayer.File, layer: ScanLayer, scanDirectory: URL) throws {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: downloaded) }
        guard try sha256(of: downloaded) == file.sha256.lowercased() else { throw ChangedOnServer() }
        var root = scanDirectory.appendingPathComponent(folder)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        let staging = root.appendingPathComponent(".\(layer.kind)-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try fm.moveItem(at: downloaded, to: staging.appendingPathComponent(file.name))
            try JSONEncoder().encode(layer).write(to: staging.appendingPathComponent(documentName), options: .atomic)
            let target = directory(scanDirectory: scanDirectory, kind: layer.kind)
            let old = root.appendingPathComponent(".old-\(layer.kind)-\(UUID().uuidString)")
            if fm.fileExists(atPath: target.path) { try fm.moveItem(at: target, to: old) }
            try fm.moveItem(at: staging, to: target)
            try? fm.removeItem(at: old)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    static func remove(scanDirectory: URL, kind: String) {
        try? FileManager.default.removeItem(at: directory(scanDirectory: scanDirectory, kind: kind))
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Downloads

/// How a layer download ended, as the session reports it to `ScanLayers`.
nonisolated enum LayerDownloadOutcome: Sendable {
    /// The file, moved aside before the session deleted it.
    case downloaded(URL)
    /// Why it failed, and what resumes it (a dropped connection, not a refusal).
    case failed(String, resumeData: Data?)
}

/// The URLSession layer downloads go through: progress, resume data after a failure, and the
/// control plane's certificate rule (`ControlPlaneSession`). Its callbacks run on the session's queue
/// and hand over to the main actor; a tap starts each download, so it is a foreground session.
nonisolated enum LayerDownloads {
    private static let delegate = LayerDownloadDelegate()
    static let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

    /// Starts `request`, or resumes from `resumeData`, reporting to `ScanLayers` under `key`.
    @discardableResult
    static func start(_ request: URLRequest, resumeData: Data?, key: String) -> URLSessionDownloadTask {
        let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: request)
        delegate.track(task.taskIdentifier, key: key)
        task.resume()
        return task
    }
}

nonisolated final class LayerDownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private let keys = OSAllocatedUnfairLock(initialState: [Int: String]())
    private let landed = OSAllocatedUnfairLock(initialState: [Int: URL]())
    private let percents = OSAllocatedUnfairLock(initialState: [Int: Int]())

    func track(_ id: Int, key: String) {
        keys.withLock { $0[id] = key }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        ControlPlaneSession.disposition(for: challenge)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskIdentifier
        guard totalBytesExpectedToWrite > 0, let key = keys.withLock({ $0[id] }) else { return }
        // A step per whole percent, not per chunk: the main actor redraws the card for each.
        let percent = Int(100 * totalBytesWritten / totalBytesExpectedToWrite)
        let changed = percents.withLock { (last: inout [Int: Int]) -> Bool in
            guard last[id] != percent else { return false }
            last[id] = percent
            return true
        }
        guard changed else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in ScanLayers.shared.progressed(key, fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The session deletes the file once this returns: move it aside now. An error status
        // downloads its body too; that one is not kept, and didComplete reports the status.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { return }
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("layer-\(UUID().uuidString)")
        if (try? FileManager.default.moveItem(at: location, to: kept)) != nil {
            landed.withLock { $0[downloadTask.taskIdentifier] = kept }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        guard let key = keys.withLock({ $0.removeValue(forKey: id) }) else { return }
        _ = percents.withLock { $0.removeValue(forKey: id) }
        let file = landed.withLock { $0.removeValue(forKey: id) }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let outcome: LayerDownloadOutcome
        if let error = error as? URLError {
            let host = task.originalRequest?.url?.host() ?? ""
            let text = ControlPlaneClient.failure(for: error, host: host).errorDescription ?? error.localizedDescription
            outcome = .failed(text, resumeData: error.downloadTaskResumeData)
        } else if let error {
            outcome = .failed(error.localizedDescription, resumeData: nil)
        } else if status == 401 {
            outcome = .failed(ControlPlaneClient.Failure.unauthorized.errorDescription ?? "", resumeData: nil)
        } else if let file {
            outcome = .downloaded(file)
        } else {
            outcome = .failed(ControlPlaneClient.Failure.server(status: status, detail: "").errorDescription ?? "",
                              resumeData: nil)
        }
        Task { @MainActor in ScanLayers.shared.finished(key, outcome) }
    }
}

// MARK: - What the phone knows

/// Each scan's layers as the server last reported them, the copies on this phone, and the downloads
/// under way: what a scan card's layer line shows (`LayerLine`), and later the viewers.
@Observable
@MainActor
final class ScanLayers {
    static let shared = ScanLayers()

    /// What a card says about one layer of its scan.
    nonisolated enum Line: Equatable, Sendable {
        /// On the server, not on this phone.
        case available(bytes: Int64, stale: Bool)
        case downloading(Double)
        /// On this phone, the server's latest.
        case ready(stale: Bool)
        /// On this phone, and the server has a newer one.
        case update(bytes: Int64)
        /// On this phone at another level (`onPhone`, a role) than the Server tab's Splat Quality; that
        /// level is on the server.
        case otherLevel(onPhone: String, bytes: Int64)
        /// On this phone; the server no longer reports one.
        case localOnly
        case failed(String)
    }

    /// Each scan's layers as the last sync that reported the scan carried them.
    private(set) var remote: [UUID: [ScanLayer]] = ScanLayers.storedRemote()
    /// Each copy on this phone (`LayerCache`), by key, once read from disk (`readLocal`).
    private(set) var local: [String: ScanLayer] = [:]
    /// Downloads under way: the fraction done, by key.
    private(set) var downloading: [String: Double] = [:]
    /// The last download's failure, by key, until the next try.
    private(set) var failures: [String: String] = [:]
    private var readKeys: Set<String> = []
    private var pending: [String: (layer: ScanLayer, file: ScanLayer.File, scanDirectory: URL)] = [:]
    private var resumeData: [String: Data] = [:]

    nonisolated static func key(_ scanId: UUID, _ kind: String) -> String { "\(scanId.uuidString)/\(kind)" }

    func layer(_ scanId: UUID, kind: String) -> ScanLayer? {
        remote[scanId]?.first { $0.kind == kind }
    }

    func line(for scanId: UUID, kind: String = ScanLayer.splat, quality: SplatQuality = .current) -> Line? {
        let key = Self.key(scanId, kind)
        return Self.line(remote: layer(scanId, kind: kind), local: local[key], quality: quality,
                         downloading: downloading[key], failure: failures[key])
    }

    nonisolated static func line(remote: ScanLayer?, local: ScanLayer?, quality: SplatQuality, downloading: Double?,
                                 failure: String?) -> Line? {
        if let downloading { return .downloading(downloading) }
        switch (remote, local) {
        case (nil, nil):
            return nil
        case (nil, .some):
            return .localOnly
        case (let layer?, nil):
            if let failure { return .failed(failure) }
            return .available(bytes: layer.file(for: quality)?.bytes ?? 0, stale: layer.isStale)
        case (let layer?, let copy?):
            let wanted = layer.file(for: quality)
            let held = copy.installedFile?.role ?? ScanLayer.fullRole
            if copy.version == layer.version, wanted == nil || wanted?.role == held { return .ready(stale: layer.isStale) }
            if let failure { return .failed(failure) }
            if copy.version == layer.version { return .otherLevel(onPhone: held, bytes: wanted?.bytes ?? 0) }
            return .update(bytes: wanted?.bytes ?? 0)
        }
    }

    // MARK: Sync

    /// The sync reply's layers. A scan the sync reported gets exactly the layers the reply lists for
    /// it (none: the server has none, or removed it); a scan it didn't report keeps what was known.
    /// `nil` (a server from before layers) changes nothing.
    func received(_ layers: [ScanLayer]?, reported: Set<UUID>) {
        guard let layers else { return }
        let merged = Self.merged(remote, with: layers, reported: reported)
        guard merged != remote else { return }
        remote = merged
        store()
    }

    nonisolated static func merged(_ known: [UUID: [ScanLayer]], with layers: [ScanLayer],
                                   reported: Set<UUID>) -> [UUID: [ScanLayer]] {
        var next = known
        for id in reported { next[id] = nil }
        for layer in layers {
            guard let id = layer.scanId, reported.contains(id) else { continue }
            next[id, default: []].append(layer)
        }
        return next
    }

    /// Another server: what this one reported was that one's. The copies on the phone stay.
    func serverChanged() {
        remote = [:]
        failures = [:]
        store()
    }

    // MARK: The copy on this phone

    /// Reads the scan's copy from disk once (off the main thread), so its line knows it.
    func readLocal(scanId: UUID, scanDirectory: URL, kind: String = ScanLayer.splat) async {
        let key = Self.key(scanId, kind)
        guard !readKeys.contains(key) else { return }
        readKeys.insert(key)
        let found = await Task.detached(priority: .utility) {
            LayerCache.local(scanDirectory: scanDirectory, kind: kind)
        }.value
        if let found { local[key] = found }
    }

    func remove(scanId: UUID, scanDirectory: URL, kind: String = ScanLayer.splat) {
        let key = Self.key(scanId, kind)
        local[key] = nil
        failures[key] = nil
        Task.detached(priority: .utility) { LayerCache.remove(scanDirectory: scanDirectory, kind: kind) }
    }

    // MARK: Downloading

    /// Downloads the server's latest copy of the scan's layer at `quality` (resuming a broken
    /// download), then swaps it in for the copy on this phone. Nothing without a control plane.
    func download(scanId: UUID, scanDirectory: URL, kind: String = ScanLayer.splat, quality: SplatQuality = .current) {
        let key = Self.key(scanId, kind)
        guard downloading[key] == nil, let client = ControlPlaneSync.shared.client,
              let layer = self.layer(scanId, kind: kind), let file = layer.file(for: quality) else { return }
        // Resume data is for one file of one version: another starts afresh.
        if pending[key]?.layer.version != layer.version || pending[key]?.file.name != file.name { resumeData[key] = nil }
        failures[key] = nil
        downloading[key] = 0
        var copy = layer
        copy.installedRole = file.role
        pending[key] = (copy, file, scanDirectory)
        LayerDownloads.start(client.layerFileRequest(file), resumeData: resumeData.removeValue(forKey: key), key: key)
    }

    func progressed(_ key: String, _ fraction: Double) {
        guard downloading[key] != nil else { return }
        downloading[key] = fraction
    }

    func finished(_ key: String, _ outcome: LayerDownloadOutcome) {
        guard let job = pending[key] else { return }
        switch outcome {
        case .failed(let message, let resume):
            downloading[key] = nil
            failures[key] = message
            resumeData[key] = resume
            PerfDiag.log("[Layers] \(key): download failed: \(message)")
        case .downloaded(let file):
            Task {
                do {
                    try await Task.detached(priority: .utility) {
                        try LayerCache.install(file, file: job.file, layer: job.layer, scanDirectory: job.scanDirectory)
                    }.value
                    local[key] = job.layer
                    pending[key] = nil
                    PerfDiag.log("[Layers] \(key): version \(job.layer.version) on this phone")
                } catch {
                    failures[key] = error.localizedDescription
                    resumeData[key] = nil
                    PerfDiag.log("[Layers] \(key): not installed: \(error.localizedDescription)")
                }
                downloading[key] = nil
            }
        }
    }

    // MARK: Stored

    private func store() {
        let encoded = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: remote.map { ($0.key.uuidString, $0.value) }))
        UserDefaults.standard.set(encoded, forKey: AppConstants.Key.controlPlaneLayers)
    }

    private static func storedRemote() -> [UUID: [ScanLayer]] {
        guard let data = UserDefaults.standard.data(forKey: AppConstants.Key.controlPlaneLayers),
              let stored = try? JSONDecoder().decode([String: [ScanLayer]].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }
}
