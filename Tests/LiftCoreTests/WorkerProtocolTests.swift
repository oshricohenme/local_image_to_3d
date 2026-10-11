import Foundation
import Testing
@testable import LiftCore

@Suite struct WorkerProtocolTests {
    @Test func encodesOps() {
        let run = WorkerOp.run(job: "j", step: 1, task: "image_to_3d", inputs: ["image": "/in/a.png"], settings: ["size": .float(2)], outDir: "/out")
        #expect(run.line == #"{"inputs":{"image":"/in/a.png"},"job":"j","op":"run","out_dir":"/out","settings":{"size":2},"step":1,"task":"image_to_3d"}"# + "\n")
        #expect(WorkerOp.shutdown.line == #"{"op":"shutdown"}"# + "\n")
    }

    @Test(arguments: [
        (#"{"ev":"ready","protocol":1,"load_seconds":2.5}"#, WorkerEvent.ready(protocol: 1, loadSeconds: 2.5)),
        (#"{"ev":"log","job":"j","line":"hi"}"#, .log(job: "j", line: "hi")),
        (#"{"ev":"stage","job":"j","name":"Sampling","fraction":0.5}"#, .stage(job: "j", name: "Sampling", fraction: 0.5)),
        (#"{"ev":"stage","job":"j","name":"Load","fraction":null}"#, .stage(job: "j", name: "Load", fraction: nil)),
        (#"{"ev":"done","job":"j","outputs":["/o.glb"]}"#, .done(job: "j", outputs: ["/o.glb"])),
        (#"{"ev":"error","job":"j","message":"boom","traceback":"tb"}"#, .error(job: "j", message: "boom", traceback: "tb")),
        (#"{"ev":"error","job":null,"message":"load failed"}"#, .error(job: nil, message: "load failed", traceback: nil)),
        (#"{"ev":"heartbeat","mps_allocated":123}"#, .heartbeat(mpsAllocated: 123)),
        (#"{"ev":"mystery"}"#, .malformed(#"{"ev":"mystery"}"#)),
        ("not json", .malformed("not json")),
        (#"{"ev":"log","job":"j"}"#, .malformed(#"{"ev":"log","job":"j"}"#)),
    ])
    func decodesEvents(line: String, expected: WorkerEvent) {
        #expect(WorkerEvent.decode(line) == expected)
    }
}
