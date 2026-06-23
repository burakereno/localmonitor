import XCTest
@testable import LocalMonitor

@MainActor
final class PortGroupingTests: XCTestCase {
    func testGroupsPortsByProjectOwnerAndPrefersPort3000() {
        let ports = [
            port(3000, owner: "meetcase", pid: 12273, command: "node", commandLine: "next-server"),
            port(3001, owner: "meetcase", pid: 12274, command: "node"),
            port(5037, owner: "meetcase-mobile", pid: 69269, command: "adb")
        ]

        let groups = LocalMonitorModel.groupPorts(ports)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first(where: { $0.title == "meetcase" })?.ports.count, 2)
        XCTAssertEqual(groups.first(where: { $0.title == "meetcase" })?.primaryPort.port, 3000)
        XCTAssertEqual(groups.first(where: { $0.title == "meetcase-mobile" })?.primaryPort.port, 5037)
    }

    func testSeparatesSystemAndEmulatorPortsFromPrimaryPorts() {
        let ports = [
            port(3000, owner: "meetcase", pid: 12273, command: "node", commandLine: "next-server"),
            port(5554, owner: "meetcase", pid: 857, command: "qemu-system"),
            port(6402, owner: "meetcase", pid: 1064, command: "netsimd")
        ]

        let primary = ports.filter { !$0.isSystemOrEmulatorPort }
        let system = ports.filter(\.isSystemOrEmulatorPort)

        XCTAssertEqual(LocalMonitorModel.groupPorts(primary).first?.primaryPort.port, 3000)
        XCTAssertEqual(LocalMonitorModel.groupPorts(system).first?.ports.count, 2)
    }

    private func port(
        _ port: Int,
        owner: String,
        pid: Int32,
        command: String,
        commandLine: String? = nil
    ) -> DiscoveredPort {
        DiscoveredPort(
            port: port,
            pid: pid,
            command: command,
            user: "burak",
            endpoint: "*:\(port)",
            workingDirectory: nil,
            inferredProjectName: owner,
            commandLine: commandLine,
            startedAt: nil,
            pinnedName: nil,
            isIgnored: false,
            isManaged: false,
            projectId: nil,
            projectName: nil
        )
    }
}
