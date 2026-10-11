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

    @Test func budgetCountsReservedWorkers() {
        let w = WorkerSnapshot(recipe: "other", freeCapacity: 1, reserved: 40 * gb)
        #expect(run([c("a")], workers: [w], slots: 2) == [.wait("a", .memory(needed: 12 * gb, free: 8 * gb))])
    }

    @Test func systemFreeMemoryIsChecked() {
        #expect(run([c("a")], free: 5) == [.wait("a", .memory(needed: 12 * gb, free: 5 * gb))])
    }

    @Test func existingWorkerNeedsOnlyJobMemory() {
        let w = WorkerSnapshot(recipe: "r", freeCapacity: 1, reserved: 40 * gb)
        #expect(run([c("a")], workers: [w], slots: 2) == [.start("a")])  // 2 GB fits in 48 − 40
    }

    @Test func busyWorkerMeansANewOne() {
        let w = WorkerSnapshot(recipe: "r", freeCapacity: 0, reserved: 40 * gb)
        #expect(run([c("a")], workers: [w], slots: 2) == [.wait("a", .memory(needed: 12 * gb, free: 8 * gb))])
    }

    @Test func startsDeductResources() {
        #expect(run([c("a", position: 1, load: 20), c("b", position: 2, load: 20), c("c", position: 3, load: 20)], slots: 3)
                == [.start("a"), .start("b"), .wait("c", .memory(needed: 22 * gb, free: 4 * gb))])
    }

    @Test func aWaitingJobDoesNotBlockSmallerOnes() {
        #expect(run([c("big", position: 1, load: 60), c("small", position: 2, load: 1)], slots: 2)
                == [.wait("big", .memory(needed: 62 * gb, free: 48 * gb)), .start("small")])
    }

    @Test func forceStartSkipsMemoryButNotSlots() {
        #expect(run([c("a", force: true, load: 100)]) == [.start("a")])
        #expect(run([c("a", force: true, load: 100)], running: 1) == [.wait("a", .noFreeSlot)])
    }

    @Test func modelStatesAndPause() {
        #expect(run([c("i", model: .installing), c("n", model: .notInstalled), c("u", model: .unsupported), c("w", model: .weightsUnverified)], slots: 4)
                == [.wait("i", .modelInstalling), .wait("n", .modelNotInstalled), .wait("u", .modelUnsupported), .wait("w", .weightsUnverified)])
        #expect(run([c("a", force: true)], paused: true) == [.wait("a", .queuePaused)])
    }
}
