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

    func testParsesMacOSProcessStartDate() throws {
        let date = try XCTUnwrap(PortScanner.parseProcessStartDate("Sun Jun 21 23:16:07 2026    "))
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 6)
        XCTAssertEqual(components.day, 21)
        XCTAssertEqual(components.hour, 23)
        XCTAssertEqual(components.minute, 16)
        XCTAssertEqual(components.second, 7)
    }

    func testParsesMacOSProcessStartDateWithPaddedDay() throws {
        let date = try XCTUnwrap(PortScanner.parseProcessStartDate("Mon Jun  1 09:04:03 2026"))
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 6)
        XCTAssertEqual(components.day, 1)
        XCTAssertEqual(components.hour, 9)
        XCTAssertEqual(components.minute, 4)
        XCTAssertEqual(components.second, 3)
    }
}
