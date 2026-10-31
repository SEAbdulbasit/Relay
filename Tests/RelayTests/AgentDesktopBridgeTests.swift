import Foundation
import Testing
@testable import Relay

@Suite("AgentDesktopBridge & FFI Integration Tests")
struct AgentDesktopBridgeTests {
    @Test("Resolves vendored agent-desktop CLI and verifies libagent_desktop_ffi.dylib ABI v6")
    func resolvesBinaryAndVerifiesFfiAbi() async throws {
        let execURL = AgentDesktopBridge.resolveExecutableURL()
        #expect(execURL != nil)

        let ffiURL = AgentDesktopBridge.resolveFfiLibraryURL()
        #expect(ffiURL != nil)

        let ffiCheck = AgentDesktopBridge.verifyFfiLibrary()
        #expect(ffiCheck.loaded == true)
        #expect(ffiCheck.abiMajor == 6)

        let status = await AgentDesktopBridge.queryStatus()
        #expect(status.available == true)
        #expect(status.ffiLoaded == true)
        #expect(!status.version.isEmpty)
    }

    @Test("Executes agent-desktop version and permissions commands via JSON envelope parser")
    func executesVersionAndPermissionsCommands() async throws {
        let verEnv = try await AgentDesktopBridge.runCommand(arguments: ["version"])
        #expect(verEnv.ok == true)
        #expect(verEnv.command == "version")
        #expect(verEnv.rawJSON.contains("\"version\""))

        let permEnv = try await AgentDesktopBridge.runCommand(arguments: ["permissions"])
        #expect(permEnv.ok == true)
        #expect(permEnv.command == "permissions")
    }
}
