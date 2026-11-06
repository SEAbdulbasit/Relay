import Foundation
import Testing
@testable import Relay

@Suite("Agent desktop subprocess lifecycle")
struct AgentDesktopProcessRunnerTests {
    private let python = URL(fileURLWithPath: "/usr/bin/python3")

    @Test func drainsBothPipesBeyondPipeCapacity() async throws {
        let result = try await AgentDesktopProcessRunner.run(executable: python, arguments: ["-c", "import os; os.write(1,b'o'*250000); os.write(2,b'e'*250000)"], timeoutSeconds: 5)
        #expect(result.stdout == Data(repeating: 111, count: 250_000))
        // Apple's Python launcher may prepend a sandbox temp-directory warning.
        #expect(result.stderr.suffix(250_000) == Data(repeating: 101, count: 250_000))
        #expect(result.stderr.count < 254_096)
        #expect(result.exitStatus == 0)
    }

    @Test func outputLimitRefusesInsteadOfTruncatingSuccess() async {
        do {
            _ = try await AgentDesktopProcessRunner.run(executable: python, arguments: ["-c", "import os; os.write(1,b'x'*200000)"], outputLimit: 1024)
            Issue.record("Expected bounded output failure")
        } catch {
            #expect(error.localizedDescription.contains("capture limit"))
        }
    }

    @Test func timeoutKillsChildThatIgnoresTermination() async {
        let start = Date()
        do {
            _ = try await AgentDesktopProcessRunner.run(executable: python, arguments: ["-c", "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(30)"], timeoutSeconds: 0.2)
            Issue.record("Expected timeout")
        } catch {
            #expect(error.localizedDescription.contains("timed out"))
            #expect(Date().timeIntervalSince(start) < 5)
        }
    }

    @Test func cancellationStopsRunningChild() async throws {
        let task = Task {
            try await AgentDesktopProcessRunner.run(executable: python, arguments: ["-c", "import time; time.sleep(30)"], timeoutSeconds: 20)
        }
        try await Task.sleep(for: .milliseconds(100))
        let start = Date()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            #expect(Date().timeIntervalSince(start) < 5)
        }
    }

    @Test func preservesNonzeroExitAndPartialOutput() async throws {
        let result = try await AgentDesktopProcessRunner.run(executable: python, arguments: ["-c", "import os; os.write(1,b'{partial'); os.write(2,b'failure'); raise SystemExit(7)"])
        #expect(result.exitStatus == 7)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "{partial")
        #expect(String(decoding: result.stderr, as: UTF8.self).hasSuffix("failure"))
    }
}
