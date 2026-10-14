import Foundation

extension Recipe {
    /// Structural checks beyond decoding. Empty means valid.
    func problems(folder: URL, matchFolder: Bool) -> [String] {
        var out: [String] = []
        if id.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) == nil {
            out.append("id must be lowercase letters, digits and dashes")
        }
        if matchFolder && folder.lastPathComponent != id { out.append("id \(id) must match its folder name \(folder.lastPathComponent)") }
        if (repo == nil) != (commit == nil) { out.append("repo and commit go together") }
        if let commit, commit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) == nil {
            out.append("commit must be a full 40-character sha")
        }
        if platform.status == .unsupported && (platform.reason ?? "").isEmpty {
            out.append("platform.reason is required when unsupported")
        }
        for w in weights where w.repo.split(separator: "/").count != 2 {
            out.append("weights: \(w.repo) must be owner/name")
        }
        for w in weights where w.files?.isEmpty == true { out.append("weights: \(w.repo): files must list at least one path") }
        out += attribution.problems
        for e in errors where (try? NSRegularExpression(pattern: e.match)) == nil || e.message.isEmpty {
            out.append("errors: \(e.match) needs a valid regular expression and a message")
        }
        // Bounds keep every number convertible to bytes without trapping.
        func gbOK(_ v: Double) -> Bool { v.isFinite && v > 0 && v <= 4096 }
        if !gbOK(resources.memoryGB) { out.append("resources.memory_gb must be > 0 and ≤ 4096") }
        for (i, o) in resources.memoryOverrides.enumerated() where !gbOK(o.memoryGB) {
            out.append("resources.memory_overrides[\(i)].memory_gb must be > 0 and ≤ 4096")
        }
        if !(resources.diskGB.isFinite && resources.diskGB >= 0 && resources.diskGB <= 100_000) {
            out.append("resources.disk_gb must be between 0 and 100000")
        }
        if tasks.isEmpty { out.append("at least one task is required") }
        if Set(tasks.map(\.id)).count != tasks.count { out.append("task ids must be unique") }
        let allKeys = Set(tasks.flatMap { $0.settings.map(\.key) })
        for key in resources.memoryKeys where !allKeys.contains(key) {
            out.append("resources.memory_keys: \(key) is not a setting")
        }
        for task in tasks {
            if task.inputs.isEmpty { out.append("task \(task.id): at least one input is required") }
            if Set(task.settings.map(\.key)).count != task.settings.count {
                out.append("task \(task.id): setting keys must be unique")
            }
            for def in task.settings {
                if def.type == .enum && (def.options ?? []).isEmpty {
                    out.append("task \(task.id): \(def.key): enum needs options")
                }
                if let d = def.default, case .failure(let message) = def.check(d) {
                    out.append("task \(task.id): \(def.key): default \(message)")
                }
            }
        }
        if !FileManager.default.fileExists(atPath: folder.appending(path: "launcher.py").path) {
            out.append("launcher.py is missing")
        }
        return out
    }
}

enum Checked { case success(SettingValue), failure(String) }

extension SettingDef {
    /// Type, option and range check; returns the value coerced to the declared type.
    func check(_ value: SettingValue) -> Checked {
        let coerced: SettingValue
        switch (type, value) {
        case (.int, .int): coerced = value
        case (.int, .float(let d)):
            guard let i = Int(exactly: d) else { return .failure("must be int") }  // also rejects 1e300, inf, nan
            coerced = .int(i)
        case (.float, .float(let d)):
            guard d.isFinite else { return .failure("must be a finite number") }
            coerced = value
        case (.float, .int(let i)): coerced = .float(Double(i))
        case (.bool, .bool): coerced = value
        case (.string, .string), (.path, .string): coerced = value
        case (.enum, _):
            guard let match = options?.first(where: { $0 == value || ($0.number != nil && $0.number == value.number) }) else {
                return .failure("must be one of \((options ?? []).map(\.description).joined(separator: ", "))")
            }
            coerced = match
        default:
            return .failure("must be \(type.rawValue)")
        }
        if let n = coerced.number {
            if let min, n < min { return .failure("must be ≥ \(min.formatted())") }
            if let max, n > max { return .failure("must be ≤ \(max.formatted())") }
        }
        if type == .path, case .string(let p) = coerced, !FileManager.default.fileExists(atPath: p) {
            return .failure("path does not exist: \(p)")
        }
        return .success(coerced)
    }
}

extension RecipeTask {
    /// Validates request settings and fills defaults. `prefix` names the field path in errors.
    public func validated(settings: [String: SettingValue], prefix: String) throws(LiftError) -> [String: SettingValue] {
        var out: [String: SettingValue] = [:]
        var errors: [FieldError] = []
        let known = Set(self.settings.map(\.key))
        for key in settings.keys.sorted() where !known.contains(key) {
            errors.append(FieldError("\(prefix).\(key)", "unknown setting"))
        }
        for def in self.settings {
            guard let value = settings[def.key] ?? def.default else {
                errors.append(FieldError("\(prefix).\(def.key)", "required"))
                continue
            }
            switch def.check(value) {
            case .success(let v): out[def.key] = v
            case .failure(let message): errors.append(FieldError("\(prefix).\(def.key)", message))
            }
        }
        if !errors.isEmpty { throw .invalidInput(errors) }
        return out
    }

    /// Checks input names and that files exist. A chained step may leave its first input out.
    public func validated(inputs: [String: String], chained: Bool, prefix: String, workdir: URL? = nil) throws(LiftError) -> [String: String] {
        var errors: [FieldError] = []
        let known = Set(self.inputs.map(\.name))
        for name in inputs.keys.sorted() where !known.contains(name) {
            errors.append(FieldError("\(prefix).\(name)", "unknown input"))
        }
        for (i, input) in self.inputs.enumerated() {
            guard let value = inputs[input.name] else {
                if !(chained && i == 0) { errors.append(FieldError("\(prefix).\(input.name)", "required")) }
                continue
            }
            var isDir: ObjCBool = false
            switch input.type {
            case .text:
                break
            case .imageSet:
                if let problem = ImageSet.problem(URL(filePath: value), workdir: workdir) {
                    errors.append(FieldError("\(prefix).\(input.name)", problem))
                }
            default:
                if !FileManager.default.fileExists(atPath: value, isDirectory: &isDir) || isDir.boolValue {
                    errors.append(FieldError("\(prefix).\(input.name)", "must be an existing file: \(value)"))
                }
            }
        }
        if !errors.isEmpty { throw .invalidInput(errors) }
        return inputs
    }
}

/// An `image_set` input: a flat folder of images plus an optional `transforms.json` (hidden files ignored).
public enum ImageSet {
    public static let extensions: Set<String> = ["png", "jpg", "jpeg", "webp"]
    public static let maxImages = 64
    public static let maxBytes = 2_000_000_000

    /// The files that make up the set (what gets copied), or nil if the folder can't be read.
    public static func files(_ folder: URL) -> [URL]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        return names.filter { !$0.hasPrefix(".") }.sorted().map { folder.appending(path: $0) }
    }

    /// Why `folder` isn't a valid image set, or nil.
    public static func problem(_ folder: URL, workdir: URL?) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            return "must be an existing folder: \(folder.path)"
        }
        let resolved = folder.resolvingSymlinksInPath().standardizedFileURL.path
        if let workdir {
            let w = workdir.resolvingSymlinksInPath().standardizedFileURL.path
            if (w + "/").hasPrefix(resolved == "/" ? "/" : resolved + "/") { return "must not contain Lift's working directory" }
        }
        guard let files = files(folder) else { return "can't read \(folder.path)" }
        var images = 0, bytes = 0
        for f in files {
            var sub: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: f.path, isDirectory: &sub)
            if sub.boolValue { return "must be a flat folder of images; \(f.lastPathComponent) is a folder" }
            let name = f.lastPathComponent
            if name == "transforms.json" { continue }
            guard extensions.contains(f.pathExtension.lowercased()) else {
                return "may only hold \(extensions.sorted().joined(separator: "/")) images and transforms.json; found \(name)"
            }
            images += 1
            bytes += (try? FileManager.default.attributesOfItem(atPath: f.resolvingSymlinksInPath().path)[.size] as? Int) ?? 0
        }
        if images == 0 { return "has no images" }
        if images > maxImages { return "has \(images) images; at most \(maxImages)" }
        if bytes > maxBytes { return "is \(bytes / 1_000_000) MB; at most \(maxBytes / 1_000_000) MB" }
        return nil
    }
}
