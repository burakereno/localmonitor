import Darwin
import Foundation
import XCTest
@testable import LocalMonitor

final class ProcessTreeTests: XCTestCase {
    func testTerminateStopsRootAndChildProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "/bin/sleep 60 & wait"]

        try process.run()
        defer {
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }

        let childPID = try waitForChild(of: process.processIdentifier)
        XCTAssertTrue(Self.isAlive(process.processIdentifier))
        XCTAssertTrue(Self.isAlive(childPID))

        ProcessTree.terminate(pid: process.processIdentifier)

        XCTAssertTrue(waitUntil(timeout: 3) { !process.isRunning })
        XCTAssertTrue(waitUntil(timeout: 3) { !Self.isAlive(childPID) })
    }

    private func waitForChild(of pid: Int32) throws -> Int32 {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let childPID = ProcessTree.descendants(of: pid).first {
                return childPID
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        throw ProcessTreeTestError.childProcessTimedOut
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }

        return condition()
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0
    }
}

private enum ProcessTreeTestError: Error {
    case childProcessTimedOut
}
