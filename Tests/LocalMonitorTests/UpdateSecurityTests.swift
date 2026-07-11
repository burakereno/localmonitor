import Foundation
import XCTest
@testable import LocalMonitor

final class UpdateSecurityTests: XCTestCase {
    func testManifestAndArtifactMustMatchReleaseContract() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifact = directory.appendingPathComponent("LocalMonitor.dmg")
        try Data("abc".utf8).write(to: artifact)

        let valid = UpdateManifest(
            version: "1.2.3",
            asset: "LocalMonitor.dmg",
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            bundleIdentifier: "dev.local.LocalMonitor",
            teamIdentifier: "66K3EFBVB6"
        )
        XCTAssertNoThrow(try verify(valid, artifact: artifact))

        let wrongTeam = UpdateManifest(
            version: valid.version,
            asset: valid.asset,
            sha256: valid.sha256,
            bundleIdentifier: valid.bundleIdentifier,
            teamIdentifier: "OTHERTEAM"
        )
        XCTAssertThrowsError(try verify(wrongTeam, artifact: artifact)) {
            XCTAssertEqual($0 as? UpdateSecurityError, .teamIdentifierMismatch)
        }
    }

    private func verify(_ manifest: UpdateManifest, artifact: URL) throws {
        try UpdateSecurity.verify(
            manifest: manifest,
            artifactURL: artifact,
            expectedVersion: "1.2.3",
            expectedAsset: "LocalMonitor.dmg",
            expectedBundleIdentifier: "dev.local.LocalMonitor"
        )
    }
}
