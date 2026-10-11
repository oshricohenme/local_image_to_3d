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
}

public struct RecipeSourcesView: Codable, Sendable, Equatable {
    public struct Source: Codable, Sendable, Equatable {
        public var name: String
        /// A git URL, or the local folder for `bundled` / `bundled-local`.
        public var url: String
        public var stale: Bool
        public var recipes: [String]
    }
    public var sources: [Source]
    public var problems: [CatalogProblem]
    /// What the last bundled-recipes sync did (first launch / app update), including edits kept as `bundled-local`.
    public var bundle: BundledRecipes.Result
}

extension Lift {
    func modelView(_ id: String, disk: Bool = false) throws -> ModelView {
        let entry = catalog.entries[id]
        guard let recipe = installed[id] ?? entry?.recipe else { throw LiftError.notFound("model \(id)") }
        return ModelView(id: id, name: recipe.name, source: entry?.source, status: status(id), recipe: recipe,
                         pin: settings.pinOverrides[id] ?? entry?.recipe.commit ?? recipe.commit,
                         diskBytes: disk ? Self.diskSize(installer.dir(id)) : nil, weights: weightReports[id])
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

    /// "Using" a model (spec §4): in the background, install it, then download its weights (unless
    /// `downloadWeights` is false) and verify them. `wait` waits for all of it. Progress goes to `install.log`.
    public func modelsInstall(_ id: String, confirm: Bool = false, wait: Bool = false, downloadWeights: Bool = true) async throws -> Gated<ModelView> {
        guard let entry = catalog.entries[id] else { throw LiftError.notFound("recipe \(id)") }
        guard installing[id] == nil else { throw LiftError.invalidState("\(id) is already installing") }
        let r = entry.recipe
        guard confirm else {
            let pin = settings.pinOverrides[id] ?? r.commit
            var text = "Installs \(r.name): "
            if let repo = r.repo { text += "clones \(repo) at \(pin ?? "?"), " }
            if !r.brew.isEmpty { text += "installs \(r.brew.joined(separator: ", ")) with Homebrew, " }
            text += "creates a Python \(r.python) environment and runs \(r.install.count) install steps (about \(r.resources.diskGB.formatted()) GB)."
            if downloadWeights && !r.weights.isEmpty { text += " " + (await weightsImpact(r)) }
            return .confirmationRequired(text)
        }
        _ = try installer.preflight(entry)  // prerequisite problems reach the caller, not just the log
        try stopWorkers(of: id)
        let installer = self.installer, verifier = self.verifier
        let pin = settings.pinOverrides[id]
        phases[id] = "installing"
        let task = Task {
            let ok = (try? await installer.install(entry, pin: pin, onLine: { _ in })) != nil
            await self.rescan()
            if ok && downloadWeights && !r.weights.isEmpty {
                await self.setPhase(id, "downloading weights")
                try? await installer.downloadWeights(r, onLine: { _ in })
            }
            if ok {
                await self.setPhase(id, "verifying weights")
                await self.verified(id, await verifier.report(r))
            }
            await self.installFinished(id)
        }
        installing[id] = task
        tick()
        if wait { await task.value }
        return .done(try modelView(id))
    }

    /// "Downloads N GB from Hugging Face: repo@rev (gated), …", sizes from the API (unknown when offline).
    func weightsImpact(_ r: Recipe) async -> String {
        let size = await verifier.totalBytes(r).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "an unknown amount (offline)"
        let repos = r.weights.map { "\($0.repo)@\($0.revision)" + ($0.gated ? " (gated)" : "") }
        return "Downloads \(size) of weights from Hugging Face into the shared cache: \(repos.joined(separator: ", "))."
    }

    func setPhase(_ id: String, _ phase: String) {
        phases[id] = phase
    }

    func installFinished(_ id: String) {
        installing[id] = nil
        phases[id] = nil
        rescan()
        tick()
    }

    /// Downloads the model's weights with `hf download` from its venv, then verifies them.
    public func modelsDownloadWeights(_ id: String, confirm: Bool = false, wait: Bool = false) async throws -> Gated<ModelView> {
        guard let r = installed[id] else { throw LiftError.invalidState("\(id) is not installed") }
        guard installing[id] == nil else { throw LiftError.invalidState("\(id) is busy: \(phases[id] ?? "installing")") }
        guard !r.weights.isEmpty else { return .done(try modelView(id)) }
        guard confirm else { return .confirmationRequired(await weightsImpact(r)) }
        let installer = self.installer, verifier = self.verifier
        phases[id] = "downloading weights"
        let task = Task {
            try? await installer.downloadWeights(r, onLine: { _ in })
            await self.setPhase(id, "verifying weights")
            await self.verified(id, await verifier.report(r))
            await self.installFinished(id)
        }
        installing[id] = task
        tick()
        if wait { await task.value }
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

    public func modelsInstallLog(_ id: String) throws -> String {
        guard let text = try? String(contentsOf: installer.logURL(id), encoding: .utf8) else { throw LiftError.notFound("install log for \(id)") }
        return text
    }

    /// Model changes need its workers gone; a busy one is an error (cancel its jobs first).
    func stopWorkers(of id: String) throws {
        let mine = workers.values.filter { $0.recipe.id == id }
        if mine.contains(where: { !$0.assigned.isEmpty }) { throw LiftError.invalidState("\(id) has running jobs; cancel them first") }
        for w in mine { stop(w) }
    }

    // MARK: recipes

    public func recipesListSources() -> RecipeSourcesView {
        RecipeSourcesView(
            sources: sourceDirs.map { s in
                let url = settings.recipeSources.first { $0.name == s.name }?.url ?? s.dir.path
                return .init(name: s.name, url: url, stale: staleSources.contains(s.name),
                             recipes: catalog.entries.values.filter { $0.source == s.name }.map(\.recipe.id).sorted())
            },
            problems: catalog.problems, bundle: bundleSync)
    }

    public func recipesAddSource(_ url: String, confirm: Bool = false) async throws -> Gated<RecipeSourcesView> {
        guard !url.isEmpty else { throw LiftError.invalidInput([FieldError("url", "required")]) }
        guard !settings.recipeSources.contains(where: { $0.url == url }) else { throw LiftError.invalidState("source \(url) is already added") }
        guard confirm else { return .confirmationRequired("Clones \(url) into recipes/ and lists its recipes. Recipes run code from that repo on this Mac.") }
        guard let git = tools.git else { throw LiftError.prerequisite("git is required; run system_install_prereqs") }
        let name = RecipeSources.name(for: url, taken: Set(settings.recipeSources.map(\.name) + ["bundled", "bundled-local"]))
        try await RecipeSources(runner: config.runner, root: recipesDir, git: git, environment: toolchain.environment).clone(url: url, name: name)
        var s = settings
        s.recipeSources.append(RecipeSourceRef(name: name, url: url))
        try saveSettings(s)
        rescan()
        tick()
        return .done(recipesListSources())
    }

    public func recipesRemoveSource(_ name: String, confirm: Bool = false) throws -> Gated<RecipeSourcesView> {
        guard settings.recipeSources.contains(where: { $0.name == name }) else { throw LiftError.notFound("source \(name)") }
        guard confirm else { return .confirmationRequired("Removes recipe source \(name) and its folder. Installed models stay installed.") }
        try? FileManager.default.removeItem(at: recipesDir.appending(path: name))
        var s = settings
        s.recipeSources.removeAll { $0.name == name }
        try saveSettings(s)
        staleSources.remove(name)
        rescan()
        tick()
        return .done(recipesListSources())
    }

    /// Pulls each git source (or just `name`). A failed pull marks the source stale and keeps its last good recipes.
    public func recipesRefresh(_ name: String? = nil) async throws -> RecipeSourcesView {
        guard let git = tools.git else { throw LiftError.prerequisite("git is required; run system_install_prereqs") }
        let sources = RecipeSources(runner: config.runner, root: recipesDir, git: git, environment: toolchain.environment)
        for ref in settings.recipeSources where name == nil || ref.name == name {
            if await sources.pull(name: ref.name) { staleSources.remove(ref.name) } else { staleSources.insert(ref.name) }
        }
        rescan()
        tick()
        return recipesListSources()
    }
}
