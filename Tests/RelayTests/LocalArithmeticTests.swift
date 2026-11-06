import Testing
@testable import Relay

struct LocalArithmeticTests {
    @Test func implicitMultiplicationUsesExactDecimalArithmetic() throws {
        for op in ["x", "X", "×", "*"] {
            #expect(try LocalArithmetic.evaluate("428\(op)23445555").value == "10034697540")
        }
        #expect(try LocalArithmetic.evaluate("0.1 + 0.2").value == "0.3")
        #expect(try LocalArithmetic.evaluate("9007199254740993 + 1").value == "9007199254740994")
    }
    @Test func precedenceAssociativityAndUnaryAreConsistent() throws {
        #expect(try LocalArithmetic.evaluate("2+3*4").value == "14")
        #expect(try LocalArithmetic.evaluate("(2+3)×4").value == "20")
        #expect(try LocalArithmetic.evaluate("20 / 2 / 5").value == "2")
        #expect(try LocalArithmetic.evaluate("−(.5 + +1.5) ÷ 2").value == "-1")
        #expect(try LocalArithmetic.evaluate("4-3-2").value == "-1")
        #expect(try LocalArithmetic.evaluate("2*-3").value == "-6")
    }
    @MainActor @Test func toolDispatchValidatesAndCalculatesWithoutReviewOrDesktopAccess() async throws {
        let tools = MacTools()
        let call = ToolCall(name: "calculate", arguments: ["expression": .string("428x23445555")])
        let result = try await tools.execute(call)
        #expect(result.verified)
        #expect(result.summary == "Result: 10034697540")
        #expect(result.evidence.contains("Calculated locally"))
        let extra = ToolCall(name: "calculate", arguments: ["expression": .string("1+1"), "shell": .string("false")])
        await #expect(throws: (any Error).self) { try await tools.execute(extra) }
    }

    @Test func recurringDecimalReportsApproximation() throws {
        let result = try LocalArithmetic.evaluate("1/3")
        #expect(result.rounded)
        #expect(result.value.hasPrefix("0.333333333333333"))
        #expect(try !LocalArithmetic.evaluate("1/4").rounded)
        #expect(try !LocalArithmetic.evaluate("3/6").rounded)
        #expect(try !LocalArithmetic.evaluate("0/7").rounded)
        #expect(try LocalArithmetic.evaluate("1/6").rounded)
        #expect(try LocalArithmetic.evaluate("1/7").rounded)
    }
    @Test func malformedOrExecutableInputsAndUnboundedWorkAreRejected() {
        for input in ["", "hello", "1/0", "2/(3-3)", "1..2", "1 2", "2(3)", "(1+2", "1+2)", "1; rm -rf /", "sqrt(4)", "1e10", "50%", "NaN", String(repeating: "9", count: 39), String(repeating: "(", count: 30)+"1"+String(repeating: ")", count: 30), String(repeating: "1+", count: 129)+"1", String(repeating: " ", count: 513)] {
            #expect(throws: (any Error).self) { try LocalArithmetic.evaluate(input) }
        }
    }
}
