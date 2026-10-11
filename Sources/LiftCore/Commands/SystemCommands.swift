import Foundation
import GRDB

public struct WorkerView: Codable, Sendable, Equatable {
    public var id: String
    public var recipe: String
    public var pid: Int32
    public var ready: Bool
    public var jobs: [String]
    public var maxConcurrent: Int
    public var footprintBytes: Int
    public var reservedBytes: Int
}

public struct EstimateView: Codable, Sendable, Equatable {
    public var recipe: String
    public var task: String
    public var keyValues: String
    /// Learned peaks (max of the last 5); nil until sampled.
    public var loadBytes: Int?
    public var jobBytes: Int?
}

public struct ResourcesView: Codable, Sendable, Equatable {
    public var maxSlots: Int
    public var budgetBytes: Int
    public var reservedBytes: Int
    public var systemFreeBytes: Int
    public var workers: [WorkerView]
    public var estimates: [EstimateView]
}

extension Lift {
    // MARK: workers and resources

    public func workersList() -> [WorkerView] {
        workers.values.sorted { $0.id < $1.id }.map {
            WorkerView(id: $0.id, recipe: $0.recipe.id, pid: $0.pid, ready: $0.ready, jobs: $0.jobs,
                       maxConcurrent: $0.capacity, footprintBytes: $0.lastFootprint, reservedBytes: $0.reserved)
        }
    }

    /// Starts a worker ahead of time. The caller decides; no budget check. Weights are verified first.
    public func workersLoad(_ recipe: String) async throws -> WorkerView {
        guard let r = installed[recipe] else { throw LiftError.invalidState("\(recipe) is not installed") }
        if !r.weights.isEmpty {
            let report = try await modelsVerifyWeights(recipe)
            guard report.state == .ok else {
                throw LiftError.invalidState("\(recipe)'s weights are \(report.state.rawValue): " + report.problems.map(\.path).joined(separator: ", "))
            }
        }
        let need = try await store.db.read { try Estimates.need($0, recipe: r, task: r.tasks[0].id, settings: [:]) }
        let w = spawn(r, baseline: need.load)
        w.idleSince = .now
        return workersList().first { $0.id == w.id }!
    }

    /// Stops a worker. A busy one needs `confirm`; its running steps fail.
    public func workersUnload(_ id: String, confirm: Bool = false) throws -> Gated<[WorkerView]> {
        guard let w = workers[id] else { throw LiftError.notFound("worker \(id)") }
        if w.assigned.isEmpty {
            stop(w)
        } else {
            guard confirm else { return .confirmationRequired("Worker \(id) is running \(w.assigned.count) job(s); unloading fails them.") }
            w.process.kill()  // not `stopping`: its exit fails the running steps
        }
        return .done(workersList())
    }

    public func resourcesGet() throws -> ResourcesView {
        let estimates = try store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT DISTINCT recipe, task, keyValues FROM memorySample ORDER BY recipe, task, keyValues").map { row in
                let (recipe, task, keys): (String, String, String) = (row["recipe"], row["task"], row["keyValues"])
                return EstimateView(recipe: recipe, task: task, keyValues: keys,
                                    loadBytes: try Estimates.learned(db, recipe: recipe, task: task, keyValues: keys, kind: .load),
                                    jobBytes: try Estimates.learned(db, recipe: recipe, task: task, keyValues: keys, kind: .job))
            }
        }
        return ResourcesView(maxSlots: settings.maxSlots, budgetBytes: settings.memoryBudgetBytes,
                             reservedBytes: workers.values.reduce(0) { $0 + $1.reserved }, systemFreeBytes: config.systemFree(),
                             workers: workersList(), estimates: estimates)
    }

    public func resourcesSet(maxSlots: Int? = nil, memoryBudgetGB: Double? = nil, idleUnloadMinutes: Double? = nil) throws -> Settings {
        var s = settings
        if let maxSlots { s = try s.setting("max_slots", to: .int(maxSlots)) }
        if let memoryBudgetGB { s = try s.setting("memory_budget_gb", to: .float(memoryBudgetGB)) }
        if let idleUnloadMinutes { s = try s.setting("idle_unload_minutes", to: .float(idleUnloadMinutes)) }
        try saveSettings(s)
        tick()
        return s
    }

    // MARK: settings

    public func settingsGet() -> Settings { settings }

    public func settingsSet(_ key: String, _ value: SettingValue) throws -> Settings {
        let s = try settings.setting(key, to: value)
        try saveSettings(s)
        if key == "dev_recipes" { rescan() }
        tick()
        return s
    }

    // MARK: system

    public func systemPrereqs(checkMetal: Bool = false) async -> Prereqs {
        tools = await toolchain.detect()
        return Prereqs(tools: tools, metalToolchain: checkMetal ? await toolchain.metalToolchainInstalled() : nil)
    }

    /// Installs what's missing: native Homebrew (one administrator dialog, spec §6), then
    /// `brew install git uv` with it, and the Metal Toolchain when `metal` is set. Output streams to `onLine`.
    public func systemInstallPrereqs(metal: Bool = false, confirm: Bool = false,
                                     onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Gated<Prereqs> {
        let now = await systemPrereqs(checkMetal: metal)
        var plan: [String] = []
        if now.tools.brew == nil {
            var step = "install native Homebrew in \(toolchain.homebrewPrefix) (one administrator dialog)"
            if let rosetta = now.tools.rosettaBrew { step += "; the Intel Homebrew at \(rosetta) is left as it is" }
            plan.append(step)
        }
        let formulae = [("git", now.tools.git), ("uv", now.tools.uv)].filter { $0.1 == nil }.map(\.0)
        if !formulae.isEmpty { plan.append("brew install \(formulae.joined(separator: " "))") }
        if metal && now.metalToolchain == false { plan.append("xcodebuild -downloadComponent MetalToolchain") }
        guard !plan.isEmpty else { return .done(now) }
        guard confirm else { return .confirmationRequired("Will " + plan.joined(separator: ", then ") + ".") }
        if now.tools.brew == nil {
            guard let git = now.tools.git else {
                throw LiftError.prerequisite("installing Homebrew needs git: install the Xcode Command Line Tools (xcode-select --install)")
            }
            try await toolchain.installHomebrew(git: git, onLine: onLine)
        }
        if !formulae.isEmpty { try await toolchain.brewInstall(formulae, onLine: onLine) }
        if metal && now.metalToolchain == false { try await toolchain.installMetalToolchain(onLine: onLine) }
        return .done(await systemPrereqs(checkMetal: metal))
    }
}
