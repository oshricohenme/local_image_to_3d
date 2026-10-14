import Foundation

public struct ModelView: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// The recipe source it comes from; nil when only the installed copy is left.
    public var source: String?
    public var status: ModelStatus
    /// The installed copy when installed, else the source recipe.
    public var recipe: Recipe
    public var pin: String?
    /// Size of `models/<id>/`; only filled by `models_get`.
    public var diskBytes: Int?
    /// The last weights check this session (nil until one ran).
    public var weights: WeightsReport?
    /// While weights download (or are paused): bytes so far out of the total (nil while the total is unknown).
    public var progress: InstallProgress? = nil
    /// The model's latest download that isn't done: queued, downloading, paused, failed or cancelled.
    public var download: Download? = nil
}

/// One recipe found in `bundled-local` / `bundled`, and whether it can be used.
public struct RecipeListing: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case available
        case needsNewerLift = "needs_newer_lift"
        case invalid
        /// A developer recipe (the Test Cube) while the `dev_recipes` setting is off.
        case developerHidden = "developer_hidden"
        /// Another source's recipe with the same id is used instead.
        case shadowed
    }
    /// The recipe id (the folder name for an invalid recipe).
    public var id: String
    public var name: String?
    public var source: String
    public var state: State
    public var detail: String?
}

extension Lift {
    func modelView(_ id: String, disk: Bool = false) throws -> ModelView {
        let entry = catalog.entries[id]
        guard let recipe = installed[id] ?? entry?.recipe else { throw LiftError.notFound("model \(id)") }
        return ModelView(id: id, name: recipe.name, source: entry?.source, status: status(id), recipe: recipe,
                         pin: settings.pinOverrides[id] ?? entry?.recipe.commit ?? recipe.commit,
                         diskBytes: disk ? Self.diskSize(installer.dir(id)) : nil, weights: weightReports[id],
                         progress: currentDownload(id).flatMap { d in
                             d.state == .downloading || d.state == .paused ? d.totalBytes.map { InstallProgress(downloadedBytes: d.downloadedBytes, totalBytes: $0) } : nil
                         },
                         download: currentDownload(id))
    }

    static func diskSize(_ url: URL) -> Int {
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        var total = 0
        while let file = files?.nextObject() as? URL {
            total += (try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
        }
        return total
    }

    // MARK: models

    public func modelsList() throws -> [ModelView] {
        try Set(catalog.entries.keys).union(installed.keys).sorted().map { try modelView($0) }
    }

    public func modelsGet(_ id: String) throws -> ModelView { try modelView(id, disk: true) }

    /// "Using" a model (spec §4): in the background, install it, then queue its weights download (unless
    /// `downloadWeights` is false), which verifies them when it's done. `wait` waits for all of it.
    /// Progress goes to `install.log`.
    public func modelsInstall(_ id: String, confirm: Bool = false, wait: Bool = false, downloadWeights: Bool = true) async throws -> Gated<ModelView> {
        guard let entry = catalog.entries[id] else { throw LiftError.notFound("recipe \(id)") }
        guard installing[id] == nil else { throw LiftError.invalidState("\(id) is already installing") }
        let r = entry.recipe
        guard downloadWeights || r.prepare.isEmpty else {
            throw LiftError.invalidInput([FieldError("download_weights", "This recipe prepares model assets during installation; download_weights must be true.")])
        }
        guard confirm else {
            let pin = settings.pinOverrides[id] ?? r.commit
            var text = "Installs \(r.name): "
            if let repo = r.repo { text += "clones \(repo) at \(pin ?? "?"), " }
            if !r.brew.isEmpty { text += "installs \(r.brew.joined(separator: ", ")) with Homebrew, " }
            text += "creates a Python \(r.python) environment and runs \(r.install.count) install steps (about \(r.resources.diskGB.formatted()) GB)."
            if !r.prepare.isEmpty {
                text += " Downloads and prepares model assets before marking the model installed. Native runtimes may also download components into this model's folder. Confirming accepts the model's published terms: \(r.attribution.license.url)."
                for c in r.attribution.components where !(c.restrictions ?? []).isEmpty {
                    text += " \(c.name): \((c.restrictions ?? []).joined(separator: ", ")) (\(c.license.url))."
                }
            }
            if downloadWeights && !r.weights.isEmpty { text += " " + (await weightsImpact(r)) }
            return .confirmationRequired(text)
        }
        _ = try installer.preflight(entry)  // prerequisite problems reach the caller, not just the log
        try stopWorkers(of: id)
        let installer = self.installer, verifier = self.verifier
        let pin = settings.pinOverrides[id]
        phases[id] = "installing"
        if let d = currentDownload(id), d.state.isActive { _ = try downloadsCancel(d.id, confirm: true) }  // a reinstall starts afresh
        let task = Task {
            let ok = (try? await installer.install(entry, pin: pin, onLine: { _ in }, onPhase: { phase in await self.setPhase(id, phase) })) != nil
            await self.rescan()
            if ok && downloadWeights && !r.weights.isEmpty && !Task.isCancelled {
                _ = try? await self.enqueueDownload(r)  // the download queue carries on from here
            } else if ok && !Task.isCancelled {
                await self.setPhase(id, "verifying weights")
                await self.verified(id, await verifier.report(r))
            }
            await self.installFinished(id)
        }
        installing[id] = task
        tick()
        if wait {
            await task.value
            await settleDownload(id)
        }
        return .done(try modelView(id))
    }

    /// "Downloads N GB from Hugging Face: repo@rev (gated), …", sizes from the API (unknown when offline).
    func weightsImpact(_ r: Recipe) async -> String {
        let size = await verifier.totalBytes(r).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "an unknown amount (offline)"
        let repos = r.weights.map { "\($0.repo)@\($0.revision)" + ($0.gated ? " (gated)" : "") }
        return "Downloads \(size) of weights from Hugging Face into the shared cache: \(repos.joined(separator: ", "))."
    }

    func setPhase(_ id: String, _ phase: String) {
        guard installing[id] != nil || phases[id] != nil, phases[id] != "cancelling" else { return }
        phases[id] = phase
    }

    /// Stops an install or weights download. What's done so far stays (a partial download resumes next time);
    /// a cancelled install never counts as installed, and isn't marked failed either.
    public func modelsCancelInstall(_ id: String) throws -> ModelView {
        if let task = installing[id] {
            task.cancel()
            phases[id] = "cancelling"
        } else if let d = currentDownload(id), d.state.isActive {
            _ = try downloadsCancel(d.id, confirm: true)
        } else {
            throw LiftError.invalidState("\(id) isn't installing or downloading")
        }
        tick()
        return try modelView(id)
    }

    func installFinished(_ id: String) {
        installing[id] = nil
        phases[id] = nil
        rescan()
        tick()
    }

    /// Queues the model's weights download (`hf download` from its venv; a stopped or failed one picks up
    /// from what's in the cache), verified when it's done.
    public func modelsDownloadWeights(_ id: String, confirm: Bool = false, wait: Bool = false) async throws -> Gated<ModelView> {
        guard let r = installed[id] else { throw LiftError.invalidState("\(id) is not installed") }
        guard installing[id] == nil else { throw LiftError.invalidState("\(id) is busy: \(phases[id] ?? "installing")") }
        guard !r.weights.isEmpty else { return .done(try modelView(id)) }
        guard confirm else { return .confirmationRequired(await weightsImpact(r)) }
        try enqueueDownload(r)
        if wait { await settleDownload(id) }
        return .done(try modelView(id))
    }

    /// Checks the model's weights now. A passing check also counts for the next worker start.
    public func modelsVerifyWeights(_ id: String) async throws -> WeightsReport {
        guard let r = recipe(id) else { throw LiftError.notFound("model \(id)") }
        verifying.insert(id)
        do {
            let report = try await verifier.verify(r)
            verified(id, report)
            return report
        } catch {
            verified(id, .failedCheck(error))  // never leave the id in `verifying`
            throw error
        }
    }

    public func modelsReinstall(_ id: String, confirm: Bool = false, wait: Bool = false) async throws -> Gated<ModelView> {
        guard confirm else { return .confirmationRequired("Deletes and rebuilds \(id)'s repo and environment. Downloaded weights are kept.") }
        return try await modelsInstall(id, confirm: true, wait: wait)
    }

    /// Pins the model to `commit` and reinstalls it there.
    public func modelsSetPin(_ id: String, commit: String, confirm: Bool = false, wait: Bool = false) async throws -> Gated<ModelView> {
        guard commit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
            throw LiftError.invalidInput([FieldError("commit", "must be a full 40-character sha")])
        }
        guard catalog.entries[id] != nil else { throw LiftError.notFound("recipe \(id)") }
        guard confirm else { return .confirmationRequired("Pins \(id) to \(commit) and reinstalls it at that commit.") }
        var s = settings
        s.pinOverrides[id] = commit
        try saveSettings(s)
        return try await modelsInstall(id, confirm: true, wait: wait)
    }

    public func modelsCheckUpstream(_ id: String) async throws -> UpstreamStatus {
        guard let recipe = recipe(id) else { throw LiftError.notFound("model \(id)") }
        return try await installer.checkUpstream(recipe, pin: settings.pinOverrides[id])
    }

    /// Removes `models/<id>/` only. Weights in the shared Hugging Face cache are never deleted: Lift
    /// doesn't delete files it didn't create, and the cache is shared with other tools.
    public func modelsUninstall(_ id: String, confirm: Bool = false) throws -> Gated<ModelView?> {
        guard let recipe = recipe(id) else { throw LiftError.notFound("model \(id)") }
        guard installing[id] == nil else { throw LiftError.invalidState("\(id) is installing") }
        guard confirm else {
            return .confirmationRequired("Removes \(recipe.name)'s repo and environment (models/\(id)). Downloaded weights stay in the Hugging Face cache.")
        }
        try stopWorkers(of: id)
        try installer.uninstall(id)
        weightReports[id] = nil
        verifiedForStart.remove(id)
        rescan()
        tick()
        return .done(try? modelView(id))
    }

    /// The model's upstream README (spec §4a): Lift's own clone once installed, else fetched at the pin and
    /// cached; offline, the cached copy (`cached: true`); nil when there is none.
    public func modelsReadme(_ id: String) async throws -> Readme? {
        guard let recipe = recipe(id) else { throw LiftError.notFound("recipe \(id)") }
        return await ReadmeLoader(http: config.readmeHTTP)
            .load(recipe, pin: settings.pinOverrides[id], modelDir: installer.dir(id), installed: installed[id] != nil)
    }

    public func modelsInstallLog(_ id: String) throws -> String {
        guard let text = try? String(contentsOf: installer.logURL(id), encoding: .utf8) else { throw LiftError.notFound("install log for \(id)") }
        return text
    }

    /// Model changes need its workers gone; a busy one is an error (cancel its jobs first).
    func stopWorkers(of id: String) throws {
        let mine = workers.values.filter { $0.recipe.id == id }
        if mine.contains(where: { $0.job != nil }) { throw LiftError.invalidState("\(id) has running jobs; cancel them first") }
        for w in mine { stop(w) }
    }

    // MARK: recipes

    /// Every recipe found, available or not (spec §4: recipes are the only entry point).
    public func recipesList() -> [RecipeListing] {
        var out = catalog.entries.values.map {
            RecipeListing(id: $0.recipe.id, name: $0.recipe.name, source: $0.source, state: .available, detail: nil)
        }
        for p in catalog.problems {
            switch p {
            case .invalid(let source, let folder, let message):
                out.append(RecipeListing(id: folder, name: nil, source: source, state: .invalid, detail: message))
            case .needsNewerLift(let source, let id, let schema):
                out.append(RecipeListing(id: id, name: nil, source: source, state: .needsNewerLift, detail: "recipe schema \(schema); this Lift reads \(Recipe.supportedSchema)"))
            case .duplicate(let id, let kept, let ignored):
                out.append(RecipeListing(id: id, name: nil, source: ignored, state: .shadowed, detail: "the copy in \(kept) is used"))
            case .developerHidden(let source, let id):
                out.append(RecipeListing(id: id, name: nil, source: source, state: .developerHidden, detail: "turn on the dev_recipes setting to use it"))
            }
        }
        return out.sorted { ($0.id, $0.source) < ($1.id, $1.source) }
    }

    /// What the last bundled-recipes sync did (first launch / app update), incl. edits kept in `bundled-local`.
    public func recipesBundleSync() -> BundledRecipes.Result { bundleSync }
}
