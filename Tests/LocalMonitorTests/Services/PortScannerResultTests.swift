import Testing
@testable import LocalMonitor

struct PortScannerResultTests {
    @Test(arguments: [Int32(0), 1])
    func noListeningSocketsIsAnEmptyScan(status: Int32) throws {
        let ports = try PortScanner.ports(from: ShellResult(status: status, stdout: "", stderr: ""))
        #expect(ports.isEmpty)
    }

    @Test(arguments: [
        ShellResult(status: 1, stdout: "", stderr: "lsof: permission denied"),
        ShellResult(status: 124, stdout: "", stderr: "Command timed out"),
        ShellResult(status: 2, stdout: "", stderr: "")
    ])
    func actualCommandFailuresAreStillReported(result: ShellResult) {
        #expect(throws: PortScannerError.self) {
            try PortScanner.ports(from: result)
        }
    }

    @Test func partialResultsArePreservedWhenLsofReportsAWarning() throws {
        let output = """
        COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
        node 12345 fixture 21u IPv6 0x0 0t0 TCP *:3010 (LISTEN)
        """
        let ports = try PortScanner.ports(from: ShellResult(status: 1, stdout: output, stderr: "lsof: warning"))
        #expect(ports.map(\.port) == [3010])
    }
}
