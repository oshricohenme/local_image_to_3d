import Foundation
import GRDB
import Synchronization

/// One weights download (spec §6), from models_install, models_download_weights or a retry. Kept in the
/// database, so a quit mid-download picks up at the next launch. Nothing here ever deletes cache files:
/// paused and cancelled downloads keep their `.incomplete` files, which `hf download` resumes from.
public struct Download: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public enum State: String, Codable, Sendable {
        case queued, downloading, paused, failed, done, cancelled

        /// Still to finish: waiting, running or paused.
        public var isActive: Bool { self == .queued || self == .downloading || self == .paused }
    }

    public static let databaseTableName = "download"

    public var id: String
    public var model: String
    /// The recipe's weights: repos, revisions and the files of each.
    public var weights: [Recipe.Weight]
    public var state: State
    /// From the Hub's file sizes; nil until known (offline).
    public var totalBytes: Int?
    /// In the cache so far, finished or `.incomplete`.
    public var downloadedBytes: Int
    /// Why it failed, or the retry under way after a network error, in plain words.
    public var reason: String?
    /// For gated access: the page whose terms to accept.
    public var link: URL?
    public var attempts: Int
    /// Picked up again at launch after Lift quit mid-download ("Resuming").
    public var resumed: Bool
    /// Queue order: lower runs first.
    public var position: Int
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
}

extension Lift {
    /// Waits before each automatic retry of a network error; then the download fails with Retry.
    static let downloadBackoff: [Duration] = [.seconds(5), .seconds(20), .seconds(60)]

    // MARK: commands

    /// Every download, in queue order (finished ones too).
    public func downloadsList() -> [Download] {
        downloads.values.sorted { ($0.position, $0.createdAt) < ($1.position, $1.createdAt) }
    }

    /// Stops a running download (its whole process group) or holds a queued one. The files stay.
    public func downloadsPause(_ id: String) throws -> Download {
        var d = try download(id)
        guard d.state == .queued || d.state == .downloading else { throw LiftError.invalidState("this download is \(d.state.rawValue), not running") }
        d.state = .paused
        try save(d)
        downloadTasks.removeValue(forKey: id)?.cancel()
        pumpDownloads()
        return d
    }

    /// Puts a paused download back in the queue; `hf download` carries on from its `.incomplete` files.
    public func downloadsResume(_ id: String) throws -> Download {
        var d = try download(id)
        guard d.state == .paused else { throw LiftError.invalidState("this download is \(d.state.rawValue), not paused") }
        d.state = .queued
        try save(d)
        pumpDownloads()
        return try download(id)
    }

    /// Stops a download for good. What's downloaded stays in the cache, so a later Download picks up from there.
    public func downloadsCancel(_ id: String, confirm: Bool = false) throws -> Gated<Download> {
        var d = try download(id)
        guard d.state.isActive else { throw LiftError.invalidState("this download is \(d.state.rawValue)") }
        guard confirm else {
            return .confirmationRequired("Stops downloading \(recipe(d.model)?.name ?? d.model). What's downloaded so far stays on this Mac, "
                                         + "so downloading it again later picks up where it stopped.")
        }
        d.state = .cancelled
        d.finishedAt = Date()
        try save(d)
        downloadTasks.removeValue(forKey: id)?.cancel()
        pumpDownloads()
        tick()
        return .done(d)
    }

    /// Starts a failed or cancelled download again, from what's already in the cache.
    public func downloadsRetry(_ id: String) throws -> Download {
        var d = try download(id)
        guard d.state == .failed || d.state == .cancelled else { throw LiftError.invalidState("this download is \(d.state.rawValue), nothing to retry") }
        d.state = .queued
        d.attempts = 0
        d.reason = nil
        d.link = nil
        d.finishedAt = nil
        try save(d)
        pumpDownloads()
        return try download(id)
    }

    /// Moves a queued download to a 0-based position among the queued ones ("Download now" is 0).
    public func downloadsReorder(_ id: String, position: Int) throws -> [Download] {
        var queue = downloadsList().filter { $0.state == .queued }
        guard let from = queue.firstIndex(where: { $0.id == id }) else { throw LiftError.invalidState("only a waiting download can move") }
        let base = queue.map(\.position).min() ?? 0
        let moved = queue.remove(at: from)
        queue.insert(moved, at: min(max(0, position), queue.count))
        for (i, var d) in queue.enumerated() {
            d.position = base + i
            try save(d)
        }
        return downloadsList()
    }

    // MARK: engine

    func download(_ id: String) throws -> Download {
        guard let d = downloads[id] else { throw LiftError.notFound("download \(id)") }
        return d
    }

    func save(_ d: Download) throws {
        try store.db.write { try d.save($0) }
        downloads[d.id] = d
    }

    /// The model's latest download that isn't done: what its card shows.
    func currentDownload(_ model: String) -> Download? {
        downloads.values.filter { $0.model == model && $0.state != .done }.max { $0.createdAt < $1.createdAt }
    }

    /// Queues the recipe's weights: a new download, or its stopped or failed one again.
    @discardableResult
    func enqueueDownload(_ r: Recipe) throws -> Download {
        if let d = currentDownload(r.id) {
            if d.state.isActive { return d }
            return try downloadsRetry(d.id)
        }
        let d = Download(id: UUID().uuidString, model: r.id, weights: r.weights, state: .queued, totalBytes: nil, downloadedBytes: 0,
                         reason: nil, link: nil, attempts: 0, resumed: false,
                         position: (downloads.values.map(\.position).max() ?? 0) + 1, createdAt: Date(), startedAt: nil, finishedAt: nil)
        try save(d)
        pumpDownloads()
        tick()
        return d
    }

    /// At open: downloads that were running when Lift quit go back in the queue ("Resuming").
    static func recoverDownloads(_ db: Database) throws {
        try db.execute(sql: "UPDATE download SET state = 'queued', resumed = 1 WHERE state = 'downloading'")
    }

    /// Starts queued downloads, front first, up to `max_downloads` at once.
    func pumpDownloads() {
        guard !closing else { return }
        let all = downloadsList()
        let free = settings.maxDownloads - all.filter { $0.state == .downloading }.count
        for var d in all.filter({ $0.state == .queued }).prefix(max(0, free)) {
            guard let r = installed[d.model] else {
                d.state = .failed
                d.reason = "\(d.model) isn't installed."
                try? save(d)
                continue
            }
            d.state = .downloading
            d.startedAt = d.startedAt ?? Date()
            try? save(d)
            downloadTasks[d.id] = Task { await self.run(d.id, r) }
        }
    }

    /// Runs one download to the end: each repo with `hf download`, the cache polled each second for progress,
    /// network errors retried with backoff. A pause, cancel or quit cancels this task and sets the state itself.
    func run(_ id: String, _ r: Recipe) async {
        let verifier = self.verifier, hub = config.hfHub, repos = r.weights.map(\.repo), installer = self.installer
        let total = await verifier.totalBytes(r)  // first, so the card shows "0 of N GB" straight away
        if let total, var d = downloads[id], d.state == .downloading {
            d.totalBytes = total
            try? save(d)
        }
        // Bytes so far: the cache's blobs (finished or .incomplete), or what was there at the start plus hf's own
        // count when that's more (hf_xet may write a file's blob only once it's done).
        let reported = Reported()
        let baseline = WeightsProgress.downloadedBytes(hub: hub, repos: repos)
        let poll = Task {
            while !Task.isCancelled {
                let cache = WeightsProgress.downloadedBytes(hub: hub, repos: repos)
                await self.progressed(id, downloaded: max(cache, baseline + reported.bytes), total: total)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer { poll.cancel() }
        while true {
            do {
                try? attempt(id)
                for w in r.weights {
                    do {
                        try await installer.downloadWeight(r, w, onLine: { line in reported.read(line, repo: w.repo) })
                    } catch { throw DownloadFailure(repo: w.repo, error: error) }
                }
                await finished(id, r, .done)
                return
            } catch let failure as DownloadFailure where !Task.isCancelled {
                guard var d = downloads[id] else { return }
                switch failure.kind {
                case .gated:
                    d.reason = "Accept \(failure.repo)'s terms on Hugging Face"
                    d.link = URL(string: "https://huggingface.co/\(failure.repo)")
                case .network where d.attempts <= Self.downloadBackoff.count:
                    let wait = Self.downloadBackoff[d.attempts - 1]
                    d.reason = "Lost the connection to Hugging Face. Trying again (\(d.attempts) of \(Self.downloadBackoff.count))…"
                    try? save(d)
                    do { try await config.sleep(wait) } catch { return }
                    if Task.isCancelled { return }
                    continue
                case .network:
                    d.reason = "Lift couldn't reach Hugging Face. Check your internet connection, then press Retry."
                case .other(let message):
                    d.reason = message
                }
                try? save(d)
                await finished(id, r, .failed)
                return
            } catch {
                return  // cancelled: paused, cancelled or quitting, which set the state
            }
        }
    }

    func attempt(_ id: String) throws {
        guard var d = downloads[id] else { return }
        d.attempts += 1
        try save(d)
    }

    func progressed(_ id: String, downloaded: Int, total: Int?) {
        guard var d = downloads[id], d.state == .downloading else { return }
        let bytes = total.map { min(downloaded, $0) } ?? downloaded
        guard bytes != d.downloadedBytes || total != d.totalBytes else { return }
        d.downloadedBytes = bytes
        d.totalBytes = total ?? d.totalBytes
        try? save(d)
    }

    /// Done or failed: verify the weights (the install's last step) and start the next download.
    func finished(_ id: String, _ r: Recipe, _ state: Download.State) async {
        guard var d = downloads[id], d.state == .downloading else { return }
        d.state = state
        d.finishedAt = Date()
        if state == .done, let total = d.totalBytes { d.downloadedBytes = total; d.reason = nil }
        try? save(d)
        downloadTasks[id] = nil
        phases[r.id] = "verifying weights"
        tick()
        verified(r.id, await verifier.report(r))
        phases[r.id] = nil
        pumpDownloads()
        tick()
    }

    /// Until the model's download is done, failed, paused or cancelled, and its check has run (`wait`).
    func settleDownload(_ model: String) async {
        while let d = currentDownload(model), d.state == .queued || d.state == .downloading { try? await Task.sleep(for: .milliseconds(50)) }
        while phases[model] != nil && installing[model] == nil { try? await Task.sleep(for: .milliseconds(50)) }
    }
}

/// Why `hf download` failed, read from its output: gated access (fail at once), the network (retry), or else.
struct DownloadFailure: Error {
    enum Kind { case gated, network, other(String) }
    let repo: String
    let kind: Kind

    init(repo: String, error: any Error) {
        self.repo = repo
        let text: String
        if case LiftError.commandFailed(_, _, let tail) = error { text = tail.joined(separator: "\n") } else { text = "\(error)" }
        func has(_ pattern: String) -> Bool { text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        if has(#"GatedRepoError|Cannot access gated repo|Access to model .* is restricted|\b40[13] Client Error"#) {
            kind = .gated
        } else if has(#"ConnectionError|ConnectTimeout|ReadTimeout|Timeout|Max retries exceeded|Connection (reset|refused|aborted)|"#
                      + #"Temporary failure in name resolution|nodename nor servname|Network is unreachable|IncompleteRead|ChunkedEncodingError|5\d\d Server Error"#) {
            kind = .network
        } else {
            let last = text.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            kind = .other("The download of \(repo) stopped: \(last.map(String.init) ?? "\(error)")")
        }
    }
}

/// hf download's own progress, shared between its output and the poll.
final class Reported: Sendable {
    let progress = Mutex(HFProgress())
    var bytes: Int { progress.withLock { $0.bytes } }
    func read(_ line: String, repo: String) { progress.withLock { $0.read(line, repo: repo) } }
}
