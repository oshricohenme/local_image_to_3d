import Foundation
import Testing
@testable import LiftCore

@Suite struct SchedulerTests {
    let gb = 1_000_000_000

    func c(_ id: String, recipe: String = "r", priority: Priority = .normal, position: Double = 1, created: Double = 0,
           force: Bool = false, model: ModelReadiness = .ready, load: Int = 10, job: Int = 2) -> Candidate {
        Candidate(jobId: id, recipe: recipe, priority: priority, position: position, createdAt: Date(timeIntervalSince1970: created),
                  forceStart: force, model: model, need: MemoryNeed(load: load * gb, job: job * gb))
    }

    func run(_ cs: [Candidate], workers: [WorkerSnapshot] = [], running: Int = 0, slots: Int = 1, budget: Int = 48, free: Int = 64, paused: Bool = false) -> [Decision] {
        Scheduler.decide(SchedulerInput(candidates: cs, workers: workers, runningSteps: running, maxSlots: slots,
                                        budget: budget * gb, systemFree: free * gb, paused: paused))
    }

    @Test func oneSlotStartsTheFirst() {
        #expect(run([c("a", position: 1), c("b", position: 2)]) == [.start("a"), .wait("b", .noFreeSlot)])
    }

    @Test func orderIsPriorityThenPositionThenFIFO() {
        let d = run([c("low", priority: .low, position: 0), c("late", position: 2, created: 1), c("early", position: 2, created: 0),
                     c("moved", position: 1), c("high", priority: .high, position: 9)], slots: 5, budget: 100, free: 100)
        #expect(d == [.start("high"), .start("moved"), .start("early"), .start("late"), .start("low")])
    }

    @Test func runningStepsUseSlots() {
        #expect(run([c("a")], running: 1) == [.wait("a", .noFreeSlot)])
    }

    /// Memory never holds a job back, alone or beside another: only slots, the model and pause do.
    @Test func memoryNeverHoldsAJobBack() {
        let w = WorkerSnapshot(recipe: "other", freeCapacity: 1, reserved: 40 * gb)
        #expect(run([c("a", load: 48)], free: 40) == [.start("a")])  // TRELLIS.2: ~50 GB estimate, 40 GB free
        #expect(run([c("a", load: 100)], workers: [w], running: 1, slots: 3, free: 5) == [.start("a")])
        #expect(run([c("a", position: 1, load: 60), c("b", position: 2, load: 60)], slots: 2) == [.start("a"), .start("b")])
    }

    @Test func busyWorkerMeansANewOne() {
        let w = WorkerSnapshot(recipe: "r", freeCapacity: 0, reserved: 40 * gb)
        #expect(run([c("a"), c("b", position: 2)], workers: [w], running: 1, slots: 2) == [.start("a"), .wait("b", .noFreeSlot)])
    }

    @Test func modelStatesAndPause() {
        #expect(run([c("i", model: .installing), c("n", model: .notInstalled), c("u", model: .unsupported), c("w", model: .weightsUnverified)], slots: 4)
                == [.wait("i", .modelInstalling), .wait("n", .modelNotInstalled), .wait("u", .modelUnsupported), .wait("w", .weightsUnverified)])
        #expect(run([c("a", force: true)], paused: true) == [.wait("a", .queuePaused)])
    }
}

@Suite struct IdleUnloadTests {
    let gb = 1_000_000_000

    func input(_ cs: [Candidate], idle: [String]) -> SchedulerInput {
        SchedulerInput(candidates: cs, workers: idle.map { WorkerSnapshot(recipe: $0, freeCapacity: 1, reserved: 13 * gb) },
                       budget: 48 * gb, systemFree: 64 * gb)
    }

    @Test func aJobLoadingPastFreeMemoryUnloadsTheIdleModelsInItsWay() {
        let big = Candidate(jobId: "rig", recipe: "unirig", position: 1, need: MemoryNeed(load: 30 * gb, job: 10 * gb))
        let i = input([big], idle: ["pixal3d", "trellis"])
        let d = Scheduler.decide(i)
        #expect(d == [.start("rig")])
        #expect(Scheduler.keepLoaded(i, d) == ["unirig"])  // pixal3d and trellis go now, not after the idle timeout
    }

    @Test func idleModelsStayWhenTheNewOneFits() {
        let small = Candidate(jobId: "a", recipe: "unirig", position: 1, need: MemoryNeed(load: 2 * gb, job: 1 * gb))
        let i = input([small], idle: ["pixal3d"])
        #expect(Scheduler.keepLoaded(i, Scheduler.decide(i)) == nil)
    }

    @Test func aLoadedModelTakesItsJobWithoutUnloadingOthers() {
        let next = Candidate(jobId: "a", recipe: "trellis", position: 1, need: MemoryNeed(load: 60 * gb, job: 10 * gb))
        let i = input([next], idle: ["trellis", "pixal3d"])
        #expect(Scheduler.keepLoaded(i, Scheduler.decide(i)) == nil)
    }
}

@Suite struct BetweenJobsTests {
    let gb = 1_000_000_000

    /// After a job a model must be back near what it held when it loaded, or it's unloaded before the next job.
    @Test func aModelStillHoldingTheJobsMemoryIsUnloaded() {
        #expect(!Lift.keepsTooMuch(footprint: 15 * gb, baseline: 18 * gb))  // TRELLIS.2 after a job: freed
        #expect(!Lift.keepsTooMuch(footprint: 19 * gb, baseline: 18 * gb))
        #expect(Lift.keepsTooMuch(footprint: 30 * gb, baseline: 18 * gb))
        #expect(Lift.keepsTooMuch(footprint: 3 * gb, baseline: gb / 3))  // lazy weights: reloaded each job
    }
}
