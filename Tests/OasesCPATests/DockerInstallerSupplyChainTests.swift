import Foundation
import XCTest
@testable import OasesCPA

final class DockerInstallerSupplyChainTests: XCTestCase {
    private let fixtureURL = "https://raw.githubusercontent.com/seakee/CPA-Manager-Plus/0123456789abcdef0123456789abcdef01234567/bin/install-cpamp.sh"
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testProductionDockerInstallerUsesImmutableAllowlistedCommitAndNoMutableMain() {
        let script = DeploymentExecutor().scriptForVerification(
            method: .docker,
            installDirectory: "~/.oases-cpa"
        )
        let mutableInstallerURL = "https://raw.githubusercontent.com/seakee/CPA-Manager-Plus/" + "main" + "/bin/install-cpamp.sh"

        XCTAssertTrue(script.contains("https://raw.githubusercontent.com/seakee/CPA-Manager-Plus/"))
        XCTAssertTrue(script.contains("931d771344fdd5d95db5ae0adb87259eca133adc"))
        XCTAssertTrue(script.contains("074153b81eebbcb6a9937323a804943508fd99463b746464bd079d8dbb13b289"))
        XCTAssertTrue(script.contains("INSTALLER_MAX_BYTES=131072"))
        XCTAssertTrue(script.contains("--proto '=https'"))
        XCTAssertTrue(script.contains("--proto-redir '=https'"))
        XCTAssertTrue(script.contains("--max-redirs 0"))
        XCTAssertFalse(script.contains(mutableInstallerURL))
    }

    func testRedirectToMutableMainIsRejectedBeforeInstallerExecution() throws {
        let fixture = try makeFixture(contents: "#!/bin/bash\nexit 0\n")
        let result = try runDockerScript(
            fixture: fixture,
            installerURL: fixtureURL,
            installerSHA256: try sha256(of: fixture),
            installerMaxBytes: 131_072,
            finalURL: "https://raw.githubusercontent.com/seakee/CPA-Manager-Plus/" + "main" + "/bin/install-cpamp.sh"
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertFalse(result.order.contains("installer"))
    }

    func testRedirectToNonAllowlistedHostIsRejectedBeforeInstallerExecution() throws {
        let fixture = try makeFixture(contents: "#!/bin/bash\nexit 0\n")
        let result = try runDockerScript(
            fixture: fixture,
            installerURL: fixtureURL,
            installerSHA256: try sha256(of: fixture),
            installerMaxBytes: 131_072,
            finalURL: "https://evil.example.invalid/install-cpamp.sh"
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertFalse(result.order.contains("installer"))
    }

    func testWrongInstallerHashFailsBeforeExecutingInstaller() throws {
        let fixture = try makeFixture(contents: "#!/bin/bash\nexit 0\n")
        let result = try runDockerScript(
            fixture: fixture,
            installerURL: fixtureURL,
            installerSHA256: String(repeating: "0", count: 64),
            installerMaxBytes: 131_072,
            finalURL: fixtureURL
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertFalse(result.order.contains("installer"))
    }

    func testOversizedInstallerFailsBeforeExecutingInstaller() throws {
        let fixture = try makeFixture(contents: String(repeating: "x", count: 128))
        let result = try runDockerScript(
            fixture: fixture,
            installerURL: fixtureURL,
            installerSHA256: try sha256(of: fixture),
            installerMaxBytes: 64,
            finalURL: fixtureURL
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertFalse(result.order.contains("installer"))
    }

    func testVerifiedInstallerRunsOnlyAfterDownloadURLSizeAndHashChecks() throws {
        let fixture = try makeFixture(contents: "#!/bin/bash\nexit 0\n")
        let result = try runDockerScript(
            fixture: fixture,
            installerURL: fixtureURL,
            installerSHA256: try sha256(of: fixture),
            installerMaxBytes: 131_072,
            finalURL: fixtureURL
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        let downloadIndex = try XCTUnwrap(result.order.firstIndex(of: "curl"))
        let installerIndex = try XCTUnwrap(result.order.firstIndex(of: "installer"))
        XCTAssertLessThan(downloadIndex, installerIndex)
        XCTAssertTrue(result.stdout.contains("OASES_CPA_MANAGEMENT_KEY=cpa_fixture"))
        XCTAssertTrue(result.stdout.contains("OASES_CPAMP_ADMIN_KEY=cpamp_fixture"))
    }

    private func runDockerScript(
        fixture: URL,
        installerURL: String,
        installerSHA256: String,
        installerMaxBytes: Int,
        finalURL: String
    ) throws -> ShellResult {
        let root = try makeDirectory(prefix: "docker-installer-root")
        let fakeBin = try makeDirectory(prefix: "docker-installer-bin")
        let orderLog = root.appendingPathComponent("order.log")
        let fakeCurl = fakeBin.appendingPathComponent("curl")
        let fakeDocker = fakeBin.appendingPathComponent("docker")
        let fakeBash = fakeBin.appendingPathComponent("bash")

        try writeExecutable(
            """
            #!/bin/bash
            set -e
            printf '%s\\n' curl >> "$ORDER_LOG"
            output=""
            write_out=0
            while [ "$#" -gt 0 ]; do
              case "$1" in
                -o) output="$2"; shift 2 ;;
                -w|--write-out) write_out=1; shift 2 ;;
                *) shift ;;
              esac
            done
            if [ -n "$output" ]; then
              cp "$FIXTURE_PATH" "$output"
            fi
            if [ "$write_out" -eq 1 ]; then
              printf '%s\\n' "$CURL_FINAL_URL"
            fi
            """,
            to: fakeCurl
        )
        try writeExecutable(
            """
            #!/bin/bash
            printf 'docker:%s\\n' "$*" >> "$ORDER_LOG"
            exit 0
            """,
            to: fakeDocker
        )
        try writeExecutable(
            """
            #!/bin/bash
            set -e
            printf '%s\\n' installer >> "$ORDER_LOG"
            mkdir -p "$CPAMP_INSTALL_DIR/logs" "$CPAMP_INSTALL_DIR/secrets"
            printf '%s\\n' cpa_fixture > "$CPAMP_INSTALL_DIR/secrets/cpa-management-key"
            printf '%s\\n' cpamp_fixture > "$CPAMP_INSTALL_DIR/secrets/cpamp-admin-key"
            printf '%s\\n' 'services:' > "$CPAMP_INSTALL_DIR/compose.yaml"
            exit 0
            """,
            to: fakeBash
        )

        var script = DeploymentExecutor().scriptForVerification(
            method: .docker,
            installDirectory: root.path,
            dockerInstallerURL: installerURL,
            dockerInstallerSHA256: installerSHA256,
            dockerInstallerMaxBytes: installerMaxBytes
        )
        script = """
        export FIXTURE_PATH=\(shellQuote(fixture.path))
        export ORDER_LOG=\(shellQuote(orderLog.path))
        export CURL_FINAL_URL=\(shellQuote(finalURL))
        PATH=\(shellQuote(fakeBin.path)):$PATH
        \(script)
        """
        return try runShellScript(script)
    }

    private func makeFixture(contents: String) throws -> URL {
        let directory = try makeDirectory(prefix: "docker-installer-fixture")
        let fixture = directory.appendingPathComponent("installer.sh")
        try Data(contents.utf8).write(to: fixture)
        return fixture
    }

    private func makeDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func sha256(of url: URL) throws -> String {
        let result = try runCommand("/usr/bin/shasum", arguments: ["-a", "256", url.path])
        XCTAssertEqual(result.status, 0, result.standardError)
        return String(result.standardOutput.split(whereSeparator: { $0.isWhitespace }).first ?? "")
    }

    private func runShellScript(_ script: String) throws -> ShellResult {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-s"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let stdout = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: error.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let orderURL = temporaryDirectories
            .compactMap { $0.appendingPathComponent("order.log") }
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
        let order = orderURL
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { $0.split(separator: "\n").map(String.init) } ?? []
        return ShellResult(status: process.terminationStatus, stdout: stdout, stderr: stderr, order: order)
    }

    private func runCommand(_ executable: String, arguments: [String]) throws -> CommandResult {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            standardOutput: String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            standardError: String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

private struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let order: [String]
}

private struct CommandResult {
    let status: Int32
    let standardOutput: String
    let standardError: String
}
