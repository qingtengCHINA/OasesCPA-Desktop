import Foundation
import XCTest
@testable import OasesCPA

/// `script/e2e/start_probe_engine.sh` and `script/e2e/probe_curl.sh` (Task 18): the pins are the
/// app's, the management key never reaches a command line, and `stop` signals only its own engine.
final class ProbeEngineScriptTests: XCTestCase {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let startScript = repositoryRoot.appendingPathComponent("script/e2e/start_probe_engine.sh")
    private static let curlScript = repositoryRoot.appendingPathComponent("script/e2e/probe_curl.sh")

    private var caseDirectory: URL!

    override func setUpWithError() throws {
        // Under the scratch root (outside the repository), mode 0700; left in place afterwards.
        caseDirectory = FakeArtifacts.scratchRoot.appendingPathComponent("probe-engine-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: caseDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs `script` with /bin/bash, `OASES_SCRATCH` set to this case's directory.
    private func run(_ script: URL, _ arguments: [String], path: String = "/usr/bin:/bin:/usr/sbin:/sbin") throws -> Result {
        let stdoutURL = caseDirectory.appendingPathComponent("stdout-\(UUID().uuidString.prefix(6)).txt")
        let stderrURL = caseDirectory.appendingPathComponent("stderr-\(UUID().uuidString.prefix(6)).txt")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: Data())
        FileManager.default.createFile(atPath: stderrURL.path, contents: Data())
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        process.environment = ["PATH": path, "OASES_SCRATCH": caseDirectory.path, "HOME": caseDirectory.path, "TMPDIR": caseDirectory.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            stdout: (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? "",
            stderr: (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        )
    }

    private func value(of name: String, in script: String) -> String? {
        for line in script.split(separator: "\n") where line.hasPrefix("\(name)=\"") && line.hasSuffix("\"") {
            return String(line.dropFirst(name.count + 2).dropLast())
        }
        return nil
    }

    func testScriptPinsMatchDeploymentPinSet() throws {
        let script = try String(contentsOf: Self.startScript, encoding: .utf8)
        let engine = DeploymentPinSet.current.engine
        XCTAssertEqual(value(of: "ENGINE_TAG", in: script), engine.tag)
        let arm = try XCTUnwrap(engine.assets[.darwinARM64])
        let intel = try XCTUnwrap(engine.assets[.darwinAMD64])
        XCTAssertEqual(value(of: "ENGINE_ASSET_darwin_arm64", in: script), arm.fileName)
        XCTAssertEqual(value(of: "ENGINE_SHA256_darwin_arm64", in: script), arm.sha256)
        XCTAssertEqual(value(of: "ENGINE_ASSET_darwin_amd64", in: script), intel.fileName)
        XCTAssertEqual(value(of: "ENGINE_SHA256_darwin_amd64", in: script), intel.sha256)
        // No download source in the script: the archive on disk is the only input.
        XCTAssertFalse(script.contains("https://"), "the probe engine never downloads")
    }

    func testProbeCurlKeepsKeyOutOfArgv() throws {
        let work = caseDirectory.appendingPathComponent("probe-engine", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let key = "probe-test-" + String(repeating: "5a", count: 16)
        try Data("\(key)\n".utf8).write(to: work.appendingPathComponent("management-key"))
        try Data("23456\n".utf8).write(to: work.appendingPathComponent("port"))
        // A fake curl that records its arguments and its stdin (the config it was handed).
        let bin = caseDirectory.appendingPathComponent("fake-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let argvLog = caseDirectory.appendingPathComponent("curl-argv.txt")
        let stdinLog = caseDirectory.appendingPathComponent("curl-stdin.txt")
        let fake = bin.appendingPathComponent("curl")
        try Data("""
        #!/bin/bash
        for arg in "$@"; do printf '%s\\n' "$arg" >> '\(argvLog.path)'; done
        cat > '\(stdinLog.path)'
        printf 'HTTP/1.1 200 OK\\r\\n\\r\\n{}\\n'

        """.utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let result = try run(Self.curlScript, ["GET", "/v0/management/config"], path: "\(bin.path):/usr/bin:/bin")
        XCTAssertEqual(result.status, 0, result.stderr)
        let argv = try String(contentsOf: argvLog, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertFalse(argv.joined(separator: " ").contains(key), "the key is not an argument")
        XCTAssertTrue(argv.contains("-K"))
        XCTAssertEqual(argv.firstIndex(of: "-K").map { argv[$0 + 1] }, "-", "the config comes from stdin")
        XCTAssertTrue(argv.contains("-sS"))
        XCTAssertEqual(argv.firstIndex(of: "-D").map { argv[$0 + 1] }, "-")
        XCTAssertTrue(argv.contains("http://127.0.0.1:23456/v0/management/config"), argv.joined(separator: " "))
        XCTAssertEqual(argv.firstIndex(of: "-X").map { argv[$0 + 1] }, "GET")
        XCTAssertEqual(try String(contentsOf: stdinLog, encoding: .utf8), "header = \"Authorization: Bearer \(key)\"\n")
        XCTAssertFalse(result.stdout.contains(key) || result.stderr.contains(key))
    }

    func testStopOnlySignalsOwnedProcess() throws {
        let work = caseDirectory.appendingPathComponent("probe-engine", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        // A process whose command line does not contain the work directory.
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer {
            if sleeper.isRunning { sleeper.terminate() }
            sleeper.waitUntilExit()
        }
        try Data("\(sleeper.processIdentifier)\n".utf8).write(to: work.appendingPathComponent("engine.pid"))

        let stopped = try run(Self.startScript, ["stop"])
        XCTAssertEqual(stopped.status, 0, stopped.stderr)
        XCTAssertTrue(stopped.stderr.contains("nothing was signalled"), stopped.stderr)
        XCTAssertTrue(sleeper.isRunning, "a process the script does not own is left alone")
        XCTAssertEqual(kill(sleeper.processIdentifier, 0), 0)

        let status = try run(Self.startScript, ["status"])
        XCTAssertEqual(status.status, 3, "not reported as the probe engine")
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.path), "the work directory stays")

        // Start refuses an archive whose name or hash is not the pinned one, before anything runs.
        let bogus = caseDirectory.appendingPathComponent(DeploymentPinSet.current.engine.assets[.darwinARM64]?.fileName ?? "x.tar.gz")
        try Data("not the engine".utf8).write(to: bogus)
        let refused = try run(Self.startScript, ["start", "--archive", bogus.path])
        XCTAssertEqual(refused.status, 1, refused.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("config.yaml").path), "nothing was written")
        XCTAssertEqual(try run(Self.startScript, ["start"]).status, 2, "no archive: usage error, never a download")
    }
}
