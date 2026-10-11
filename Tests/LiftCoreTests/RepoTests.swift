import Foundation
import Testing
@testable import LiftCore

/// Real git for git commands (local file:// repos only, no network); every other command is faked.
final class GitOnlyRunner: CommandRunner {
    let fake = FakeRunner()
    func run(_ command: ShellCommand, onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        command.executable.hasSuffix("/git") ? try await SubprocessRunner().run(command, onLine: onLine) : try await fake.run(command, onLine: onLine)
    }
}

/// A local upstream with two commits and a submodule; `.gitignore` ignores `ckpt/` (where upstream code
/// might download checkpoints).
struct Upstream {
    let url: String
    let first: String
    let second: String

    static let git = "/usr/bin/git"
    /// file:// submodules are refused by default since git 2.38; allowed here only, through the environment.
    static let env = ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "protocol.file.allow", "GIT_CONFIG_VALUE_0": "always",
                      "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"]

    static func sh(_ dir: URL, _ args: [String]) async throws -> String {
        try await SubprocessRunner().output(ShellCommand(git, ["-C", dir.path] + args, environment: env)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func make() async throws -> Upstream {
        let sub = try Fixtures.tempDir(), up = try Fixtures.tempDir()
        _ = try await sh(sub, ["init", "-q", "-b", "main"])
        try "sub v1\n".write(to: sub.appending(path: "sub.txt"), atomically: true, encoding: .utf8)
        _ = try await sh(sub, ["add", "."]); _ = try await sh(sub, ["commit", "-qm", "sub"])
        _ = try await sh(up, ["init", "-q", "-b", "main"])
        try "v1\n".write(to: up.appending(path: "model.py"), atomically: true, encoding: .utf8)
        try "ckpt/\n".write(to: up.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        _ = try await sh(up, ["submodule", "add", "-q", "file://\(sub.path)", "third_party/sub"])
        _ = try await sh(up, ["add", "."]); _ = try await sh(up, ["commit", "-qm", "one"])
        let first = try await sh(up, ["rev-parse", "HEAD"])
        try "v2\n".write(to: up.appending(path: "model.py"), atomically: true, encoding: .utf8)
        _ = try await sh(up, ["commit", "-qam", "two"])
        return Upstream(url: "file://\(up.path)", first: first, second: try await sh(up, ["rev-parse", "HEAD"]))
    }
}

/// Spec §6 "Lift owns its working copy": install converges `models/<id>/repo` to the pin from any state.
@Suite struct RepoTests {
    func setup(pin: KeyPath<Upstream, String> = \.first) async throws -> (Installer, CatalogEntry, URL, Upstream) {
        let up = try await Upstream.make()
        let yaml = pixalYAML.replacingOccurrences(of: "repo: https://github.com/TencentARC/Pixal3D", with: "repo: \(up.url)")
            .replacingOccurrences(of: "commit: f7cf38429b0bd264f1995f0f8743a88b1c728b94", with: "commit: \(up[keyPath: pin])")
        let root = try Fixtures.tempDir()
        let folder = try writeRecipe(yaml, id: "pixal3d", in: root)
        try FileManager.default.createDirectory(at: root.appending(path: "shared"), withIntermediateDirectories: true)
        try "flash_attn: { standin: flash_attn }\n".write(to: root.appending(path: "shared/substitutes.yaml"), atomically: true, encoding: .utf8)
        guard case .ok(let recipe) = RecipeLoad.read(directory: folder) else { throw LiftError.invalidState("fixture") }
        let inst = Installer(runner: GitOnlyRunner(), models: try Fixtures.tempDir(), workerRuntime: URL(filePath: "/lift/runtime"),
                             tools: ToolPaths(brew: "/brew/bin/brew", git: Upstream.git, uv: "/bin/uv"),
                             toolEnvironment: Upstream.env.merging(["PATH": "/usr/bin:/bin"]) { a, _ in a },
                             hfToken: { "hf_x" }, hfHub: URL(filePath: "/hf/hub"))
        return (inst, CatalogEntry(recipe: recipe, source: "test", directory: folder, shared: root.appending(path: "shared")),
                inst.dir("pixal3d").appending(path: "repo"), up)
    }

    func head(_ repo: URL) async throws -> String { try await Upstream.sh(repo, ["rev-parse", "HEAD"]) }
    func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    @Test func installTwiceIsIdempotentAndKeepsIgnoredDownloads() async throws {
        let (inst, entry, repo, up) = try await setup()
        try await inst.install(entry, pin: nil, onLine: { _ in })
        #expect(try await head(repo) == up.first)
        #expect(try read(repo.appending(path: "third_party/sub/sub.txt")) == "sub v1\n")  // submodules too
        try FileManager.default.createDirectory(at: repo.appending(path: "ckpt"), withIntermediateDirectories: true)
        try "weights".write(to: repo.appending(path: "ckpt/model.bin"), atomically: true, encoding: .utf8)
        try await inst.install(entry, pin: nil, onLine: { _ in })
        #expect(try await head(repo) == up.first)
        #expect(try read(repo.appending(path: "ckpt/model.bin")) == "weights")  // fetched in place, not re-cloned
    }

    @Test func aCloneAtAnotherCommitMovesToThePin() async throws {
        let (inst, entry, repo, up) = try await setup()
        try await inst.install(entry, pin: nil, onLine: { _ in })
        try await inst.install(entry, pin: up.second, onLine: { _ in })
        #expect(try await head(repo) == up.second)
        #expect(try read(repo.appending(path: "model.py")) == "v2\n")
    }

    @Test func aDirtyCloneEndsExactlyAtThePin() async throws {
        let (inst, entry, repo, up) = try await setup()
        try await inst.install(entry, pin: nil, onLine: { _ in })
        try "edited\n".write(to: repo.appending(path: "model.py"), atomically: true, encoding: .utf8)
        try "stray\n".write(to: repo.appending(path: "stray.txt"), atomically: true, encoding: .utf8)
        try await inst.install(entry, pin: nil, onLine: { _ in })
        #expect(try await head(repo) == up.first)
        #expect(try read(repo.appending(path: "model.py")) == "v1\n")
        #expect(!FileManager.default.fileExists(atPath: repo.appending(path: "stray.txt").path))
        #expect(try await Upstream.sh(repo, ["status", "--porcelain"]) == "")
    }

    @Test func aCorruptGitDirIsRecloned() async throws {
        let (inst, entry, repo, up) = try await setup()
        try await inst.install(entry, pin: nil, onLine: { _ in })
        try "garbage".write(to: repo.appending(path: ".git/HEAD"), atomically: true, encoding: .utf8)
        try await inst.install(entry, pin: nil, onLine: { _ in })
        #expect(try await head(repo) == up.first)
    }

    @Test func aWrongRemoteIsRecloned() async throws {
        let (inst, entry, repo, up) = try await setup()
        try await inst.install(entry, pin: nil, onLine: { _ in })
        _ = try await Upstream.sh(repo, ["remote", "set-url", "origin", "file:///nonexistent/other.git"])
        try await inst.install(entry, pin: nil, onLine: { _ in })
        #expect(try await head(repo) == up.first)
        #expect(try await Upstream.sh(repo, ["remote", "get-url", "origin"]) == up.url)
    }

    @Test func aHalfFinishedPreviousInstallIsNotFatal() async throws {
        let (inst, entry, repo, up) = try await setup()
        try FileManager.default.createDirectory(at: repo.appending(path: "partial"), withIntermediateDirectories: true)  // repo/ but no .git
        try FileManager.default.createDirectory(at: inst.dir("pixal3d").appending(path: ".repo-staging/x"), withIntermediateDirectories: true)
        try await inst.install(entry, pin: nil, onLine: { _ in })
        #expect(try await head(repo) == up.first)
    }
}
