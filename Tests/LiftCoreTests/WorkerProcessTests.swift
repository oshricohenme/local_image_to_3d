import Foundation
import Synchronization
import Testing
@testable import LiftCore

/// Consumes a worker's events once and lets a test wait for one.
final class EventRecorder: Sendable {
    private let seen = Mutex<[WorkerEvent]>([])

    init(_ w: WorkerProcess) {
        Task { [self] in
            for await e in w.events { self.seen.withLock { $0.append(e) } }
        }
    }

    var events: [WorkerEvent] { seen.withLock { $0 } }

    /// Waits up to 20 s for an event matching ; returns everything seen so far.
    func wait(for match: (WorkerEvent) -> Bool) async throws -> [WorkerEvent] {
        let end = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < end {
            let now = events
            if now.contains(where: match) { return now }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out; saw \(events)")
        throw CancellationError()
    }
}

func isReady(_ e: WorkerEvent) -> Bool { if case .ready = e { true } else { false } }
func isDone(_ e: WorkerEvent) -> Bool { if case .done = e { true } else { false } }
func isExited(_ e: WorkerEvent) -> Bool { if case .exited = e { true } else { false } }

@Suite struct WorkerProcessTests {
    func launch(_ dir: URL, maxConcurrent: Int = 1) async throws -> WorkerProcess {
        let config = #"{"launcher":"\#(Fixtures.fixtureLauncher.path)","repo_dir":"\#(dir.path)","recipe_dir":"\#(dir.path)","max_concurrent":\#(maxConcurrent),"stages":[],"heartbeat_seconds":0.2}"#
        return WorkerProcess(executable: try await Fixtures.python(), arguments: ["-u", "-m", "lift_worker", config],
                             environment: ["PYTHONPATH": Fixtures.workerRuntime.path], workingDirectory: dir.path)
    }

    @Test func runsAJobAndReportsEverything() async throws {
        let dir = try Fixtures.tempDir()
        let w = try await launch(dir)
        let r = EventRecorder(w)
        let start = try await r.wait(for: isReady)
        #expect(start.contains { if case .started(let pid) = $0 { pid > 0 } else { false } })
        w.send(.run(job: "j1", step: 0, task: "t", inputs: [:], settings: [:], outDir: dir.appending(path: "out").path))
        let evs = try await r.wait(for: isDone)
        #expect(evs.contains(.stderr("native noise at load")))
        #expect(evs.contains(.stderr("native noise in job")))  // native output never reaches the protocol
        #expect(evs.contains(.log(job: "j1", line: "start j1")))
        #expect(evs.contains(.done(job: "j1", outputs: [dir.appending(path: "out/out.txt").path])))
        #expect(!evs.contains { if case .malformed = $0 { true } else { false } })
        w.send(.shutdown)
        #expect(try await r.wait(for: isExited).last == .exited(0))
    }

    @Test func killStopsABusyWorker() async throws {
        let dir = try Fixtures.tempDir()
        let w = try await launch(dir)
        let r = EventRecorder(w)
        _ = try await r.wait(for: isReady)
        w.send(.run(job: "j1", step: 0, task: "t", inputs: [:], settings: ["sleep": .int(60)], outDir: dir.path))
        _ = try await r.wait { $0 == .log(job: "j1", line: "start j1") }
        let t0 = ContinuousClock.now
        w.kill()
        #expect(try await r.wait(for: isExited).last == .exited(128 + SIGKILL))
        #expect(ContinuousClock.now - t0 < .seconds(5))
    }

    @Test func crashReportsExitCode() async throws {
        let dir = try Fixtures.tempDir()
        let w = try await launch(dir)
        let r = EventRecorder(w)
        _ = try await r.wait(for: isReady)
        w.send(.run(job: "j1", step: 0, task: "t", inputs: [:], settings: ["crash": .bool(true)], outDir: dir.path))
        #expect(try await r.wait(for: isExited).last == .exited(7))
    }

    @Test func heartbeatsArrive() async throws {
        let dir = try Fixtures.tempDir()
        let w = try await launch(dir)
        let r = EventRecorder(w)
        let evs = try await r.wait { if case .heartbeat = $0 { true } else { false } }
        #expect(evs.contains(.heartbeat(mpsAllocated: 0)))
        w.kill()
    }
}
