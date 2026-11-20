import Foundation
import PolicyMetadataProcess
import Testing

/// Synthetic kernel-format buffers only. No process/argv/environment lookup.
@Suite struct StandardControlArgumentParserTests {
    private func buffer(arguments: [Data], executable: String = "/owned/cli", count: Int32? = nil) -> Data {
        var argc = count ?? Int32(arguments.count), result = Data()
        withUnsafeBytes(of: &argc) { result.append(contentsOf: $0) }
        result.append(Data(executable.utf8)); result.append(contentsOf: [0, 0, 0])
        for argument in arguments { result.append(argument); result.append(0) }
        result.append(Data("ENV_PRIVATE_SENTINEL=not-an-argument\0".utf8))
        return result
    }
    private func parse(_ input: Data, capacity: Int = 1_024) -> (Int32, Int32, Int, Data) {
        var output = [CChar](repeating: 42, count: capacity), used = 0, argc: Int32 = 0
        let status = input.withUnsafeBytes { raw in
            output.withUnsafeMutableBufferPointer { target in
                relay_policy_parse_arguments(raw.bindMemory(to: UInt8.self).baseAddress, input.count,
                    target.baseAddress, target.count, &used, &argc)
            }
        }
        return (status, argc, used, Data(output.map { UInt8(bitPattern: $0) }))
    }
    @Test func kernelArgcVectorPreservesSpacesAndEmptyArgumentsWithoutIncludingEnvironment() {
        let expected = [Data("/owned/cli".utf8), Data("a b".utf8), Data()]
        let result = parse(buffer(arguments: expected))
        #expect(result.0 == 0 && result.1 == 3)
        let actual = result.3.prefix(result.2).split(separator: 0, omittingEmptySubsequences: false).dropLast().map(Data.init)
        #expect(actual == expected)
        #expect(result.3.range(of: Data("ENV_PRIVATE_SENTINEL".utf8)) == nil)
        let distinct = parse(buffer(arguments: [Data("/owned/cli".utf8), Data("a".utf8), Data("b".utf8)]))
        #expect(distinct.3.prefix(distinct.2) != result.3.prefix(result.2))
    }
    @Test func missingOrMismatchedExecutableAndBoundsRefuseRatherThanGuessingAnArgvVector() {
        let valid = buffer(arguments: [Data("/owned/cli".utf8), Data("--owned".utf8)])
        for input in [Data([0, 1]), buffer(arguments: [Data("/other/cli".utf8)]),
                      buffer(arguments: [Data("/owned/cli".utf8)], count: 257),
                      Data(valid.prefix(MemoryLayout<Int32>.size + 2))] {
            let result = parse(input)
            #expect(result.0 != 0 && result.2 == 0)
        }
        let small = parse(valid, capacity: 2)
        #expect(small.0 != 0 && small.2 == 0)
        #expect(small.3.allSatisfy { $0 == 0 })
    }
}
