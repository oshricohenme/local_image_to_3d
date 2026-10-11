import Foundation
import Testing
@testable import LiftCore

@Suite struct LinesTests {
    @Test func tailKeepsTheLastLines() {
        let t = Tail(limit: 2)
        for l in ["a", "b", "c"] { t.append(l) }
        #expect(t.lines == ["b", "c"])
    }

    @Test func logFileAppendsAcrossOpens() throws {
        let url = try Fixtures.tempDir().appending(path: "sub/log.txt")
        try LogFile(url).write("one")
        try LogFile(url).write("two")
        #expect(try String(contentsOf: url, encoding: .utf8) == "one\ntwo\n")
    }

    @Test func fieldErrorsDescribeThemselves() {
        let e = LiftError.invalidInput([FieldError("steps[0].settings.size", "must be ≥ 0.01")])
        #expect(e.description == "invalid input: steps[0].settings.size: must be ≥ 0.01")
    }
}
