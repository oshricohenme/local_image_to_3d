import Foundation
import Testing
@testable import LiftCore

/// Nothing here runs a real install: every command goes to `FakeRunner`, and the Homebrew
/// prefixes are temp folders.
@Suite struct ToolchainTests {
    /// A temp prefix with `bin/brew`.
    func prefix() throws -> String {
        let bin = try Fixtures.fakeBin(["brew"])
        let p = bin.deletingLastPathComponent().appending(path: "prefix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: bin, to: p.appending(path: "bin"))
        return p.path
    }

    func config(_ prefix: String, arch: String = "26.4-arm64") -> [String] {
        ["HOMEBREW_VERSION: 4.6.0", "HOMEBREW_PREFIX: \(prefix)", "macOS: \(arch)"]
    }

    @Test func detectsInSearchOrderAndRequiresWorkingTools() async throws {
        let first = try Fixtures.fakeBin(["git"]), second = try Fixtures.fakeBin(["git", "uv"])
        let runner = FakeRunner()
        runner.on("\(second.path)/uv --version", code: 1)  // present but broken
        let t = Toolchain(runner: runner, searchDirs: [first.path, second.path], homebrewPrefix: "/nonexistent-brew", rosettaPrefix: "/nonexistent-rosetta")
        #expect(await t.detect() == ToolPaths(git: first.path + "/git"))
        #expect(t.environment["PATH"] == "\(first.path):\(second.path)" && t.environment["GIT_TERMINAL_PROMPT"] == "0")
        // The user's own git config never applies: an LFS filter there, with git-lfs off Lift's PATH, broke UniRig's clone.
        #expect(t.environment["GIT_CONFIG_GLOBAL"] == "/dev/null" && t.environment["GIT_CONFIG_NOSYSTEM"] == "1")
    }

    @Test func nonExecutableIsIgnored() throws {
        let dir = try Fixtures.tempDir()
        try "x".write(to: dir.appending(path: "uv"), atomically: true, encoding: .utf8)
        #expect(Toolchain(runner: FakeRunner(), searchDirs: [dir.path]).find("uv") == nil)
    }

    @Test func nativeBrewMustReportItsArm64Prefix() async throws {
        let p = try prefix()
        let good = FakeRunner()
        good.on("brew config", lines: config(p))
        #expect(await Toolchain(runner: good, searchDirs: [], homebrewPrefix: p).nativeBrew() == "\(p)/bin/brew")
        let partial = FakeRunner()
        partial.on("brew --version", code: 127)  // the empty scaffold seen on the dev machine
        #expect(await Toolchain(runner: partial, searchDirs: [], homebrewPrefix: p).nativeBrew() == nil)
        let rosetta = FakeRunner()
        rosetta.on("brew config", lines: config(p, arch: "26.4-x86_64"))
        #expect(await Toolchain(runner: rosetta, searchDirs: [], homebrewPrefix: p).nativeBrew() == nil)
    }

    @Test func rosettaBrewIsReportedNeverUsed() async throws {
        let rosetta = try prefix()
        let runner = FakeRunner()
        let t = Toolchain(runner: runner, searchDirs: [], homebrewPrefix: "/nonexistent-brew", rosettaPrefix: rosetta)
        let tools = await t.detect()
        #expect(tools.rosettaBrew == "\(rosetta)/bin/brew" && tools.brew == nil)
        await #expect(throws: LiftError.self) { try await t.brewInstall(["libusb"], onLine: { _ in }) }
        #expect(!runner.displays.contains { $0.contains("install libusb") })
    }

    @Test func homebrewInstallIsOneAdminDialogThenUserSteps() async throws {
        let runner = FakeRunner()
        let t = Toolchain(runner: runner, searchDirs: ["/usr/bin"], homebrewPrefix: "/opt/homebrew")
        try await t.installHomebrew(git: "/usr/bin/git", onLine: { _ in })
        let d = runner.displays
        #expect(d.count == 7)
        #expect(d[0].hasPrefix(#"/usr/bin/osascript -e do shell script "/bin/mkdir -p " & quoted form of "/opt/homebrew" & " && /usr/sbin/chown -R ""#))
        #expect(d[0].hasSuffix(#":admin" & " " & quoted form of "/opt/homebrew" with administrator privileges"#))
        #expect(d[1...5] == ["/usr/bin/git -C /opt/homebrew init -q",
                             "/usr/bin/git -C /opt/homebrew config remote.origin.url https://github.com/Homebrew/brew",
                             "/usr/bin/git -C /opt/homebrew config remote.origin.fetch +refs/heads/*:refs/remotes/origin/*",
                             "/usr/bin/git -C /opt/homebrew fetch --force --quiet origin",
                             "/usr/bin/git -C /opt/homebrew checkout --force -B main origin/main"])
        #expect(d[6] == "/opt/homebrew/bin/brew update --force --quiet")
        #expect(!d.contains { $0.contains("/bin/rm") || $0.hasPrefix("rm ") })  // nothing is deleted
    }

    /// M16: the user name and prefix reach the admin shell script quoted, whatever they contain.
    @Test func theAdminScriptQuotesTheUserName() async throws {
        let runner = FakeRunner()
        let t = Toolchain(runner: runner, searchDirs: [], homebrewPrefix: "/opt/homebrew", userName: #"o'shri "x" $(id)"#)
        try await t.installHomebrew(git: "/usr/bin/git", onLine: { _ in })
        let script = try #require(runner.commands.first?.arguments.last)
        #expect(script == #"do shell script "/bin/mkdir -p " & quoted form of "/opt/homebrew" & " && /usr/sbin/chown -R " & quoted form of "o'shri \"x\" $(id):admin" & " " & quoted form of "/opt/homebrew" with administrator privileges"#)
    }

    @Test func brewAndMetalInstallsGoThroughTheRunner() async throws {
        let p = try prefix()
        let runner = FakeRunner()
        runner.on("brew config", lines: config(p))
        runner.on("xcrun metal", code: 1)
        let t = Toolchain(runner: runner, searchDirs: [], homebrewPrefix: p)
        #expect(await t.metalToolchainInstalled() == false)
        try await t.brewInstall(["git", "uv"], onLine: { _ in })
        try await t.installMetalToolchain(onLine: { _ in })
        #expect(runner.displays.contains("\(p)/bin/brew install git uv"))
        #expect(runner.displays.last == "/usr/bin/xcodebuild -downloadComponent MetalToolchain")
    }

    @Test func failedCommandCarriesItsTail() async throws {
        let runner = FakeRunner()
        runner.on("boom", code: 2, lines: ["one", "two"])
        await #expect(throws: LiftError.commandFailed(command: "boom", exitCode: 2, tail: ["one", "two"])) {
            try await runner.check(ShellCommand("/bin/sh", ["-c", "boom"]))
        }
    }

    @Test func realRunnerStreamsLinesAndExitCodes() async throws {
        let lines = Tail(limit: 10)
        let code = try await SubprocessRunner().run(ShellCommand("/bin/sh", ["-c", "echo out; echo err 1>&2; exit 3"]), onLine: { lines.append($0) })
        #expect(code == 3)
        #expect(Set(lines.lines) == ["out", "err"])
    }
}
