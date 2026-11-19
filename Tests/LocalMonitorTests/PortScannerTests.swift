import Foundation
import XCTest
@testable import LocalMonitor

final class PortScannerTests: XCTestCase {
    func testParsesLsofListeningPortsAndDeduplicatesSamePidPort() {
        let output = """
        COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        node    12345 burak  21u  IPv6 0x0000000000000000      0t0  TCP *:3000 (LISTEN)
        node    12345 burak  22u  IPv4 0x0000000000000000      0t0  TCP 127.0.0.1:3000 (LISTEN)
        Control 22222 burak  10u  IPv4 0x0000000000000000      0t0  TCP 127.0.0.1:5173 (LISTEN)
        """

        let ports = PortScanner.parseLsofOutput(output)

        XCTAssertEqual(ports.map(\.port), [3000, 5173])
        XCTAssertEqual(ports.first?.pid, 12345)
        XCTAssertEqual(ports.first?.command, "node")
        XCTAssertEqual(ports.last?.endpoint, "127.0.0.1:5173")
    }

    func testInfersProjectNameFromGenericWebFolderWithoutReadingPackageJSON() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("meetcase", isDirectory: true)
        let webFolder = root.appendingPathComponent("web", isDirectory: true)
        try FileManager.default.createDirectory(at: webFolder, withIntermediateDirectories: true)
        try """
        { "name": "should-not-be-used" }
        """.data(using: .utf8)?.write(to: root.appendingPathComponent("package.json"))

        let name = PortScanner.inferProjectName(workingDirectory: webFolder.path, command: "node")

        XCTAssertEqual(name, "meetcase")
    }

    func testDoesNotInferProjectNameForSystemCommand() {
        let name = PortScanner.inferProjectName(
            workingDirectory: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS",
            command: "ControlCe"
        )

        XCTAssertNil(name)
    }

    func testKernelStartDateIdentifiesTheSameProcessAcrossReads() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let birth = try XCTUnwrap(ProcessTree.startDate(of: pid))
        XCTAssertLessThanOrEqual(birth, Date())
        XCTAssertEqual(ProcessTree.startDate(of: pid), birth)
        XCTAssertNil(ProcessTree.startDate(of: -1))
    }
}
