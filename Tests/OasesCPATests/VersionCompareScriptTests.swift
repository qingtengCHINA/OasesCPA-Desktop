import XCTest
@testable import OasesCPA

/// `oases_version_gt` sourced into real bash (macOS `/bin/bash` 3.2, and a bash 5 when one is
/// installed): the comparison behind the upgrade's no-downgrade guard.
final class VersionCompareScriptTests: XCTestCase {
    private func run(_ bash: String, _ script: String) throws -> [String] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: bash)
        process.arguments = ["-c", script]
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    func testVersionGreaterThanTable() throws {
        let gt = [("v8.0.51", "v8.0.9"), ("v1.14.10", "v1.9.99"), ("24.11.1", "v24.11.0"), ("v9.0.0", "v8.99.99")]
        let notGT = [("v8.0.51", "v8.0.51"), ("v8.0.9", "v8.0.51"), ("v1.14.10+oases.26.20261107", "v1.14.10"), ("0.1.0", "0.1.0-dev")]
        var script = DeploymentScriptFragments.versionCompareFunctions() + "\n"
        for (left, right) in gt + notGT {
            script += "oases_version_gt '\(left)' '\(right)'; printf '%s\\n' \"$?\"\n"
        }
        let expected = Array(repeating: "0", count: gt.count) + Array(repeating: "1", count: notGT.count)
        let shells = ["/bin/bash", "/opt/homebrew/bin/bash", "/usr/local/bin/bash"].filter { FileManager.default.isExecutableFile(atPath: $0) }
        XCTAssertTrue(shells.contains("/bin/bash"))
        for shell in shells {
            XCTAssertEqual(try run(shell, script), expected, shell)
        }
        // An empty installed version (a 0.1.x deployment without Node or gateway) never refuses.
        XCTAssertEqual(try run("/bin/bash", DeploymentScriptFragments.versionCompareFunctions() + "\noases_version_gt '' 'v24.22.2'; echo $?\n"), ["1"])
    }
}
