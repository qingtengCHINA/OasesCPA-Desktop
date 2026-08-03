import Foundation
import Darwin
import XCTest
@testable import OasesCPA

final class DeploymentLifecycleServiceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testControlRequiresMatchingTokenAndLockPIDBeforeAnySignal() throws {
        let root = try makeDirectory()
        let process = try startSleep()
        defer { stop(process) }
        writeManagedRoot(at: root)
        writeAttempt(at: root, token: "expected", pid: process.processIdentifier)
        try write("\(process.processIdentifier + 1)\n", to: root.appendingPathComponent(".oases-cpa-deployment-lock/pid"))

        let script = DeploymentControlService().scriptForVerification(
            action: .pause,
            method: .native,
            installDirectory: root.path,
            controlToken: "wrong"
        )
        let result = try run(script: script)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(isAlive(process.processIdentifier))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".oases-cpa-paused").path))
    }

    func testCancelPreflightRejectsMalformedManagedPIDWithoutSignallingDeployment() throws {
        let root = try makeDirectory()
        let process = try startSleep()
        defer { stop(process) }
        writeManagedRoot(at: root)
        writeAttempt(at: root, token: "preflight", pid: process.processIdentifier)
        try write("\(process.processIdentifier)\n", to: root.appendingPathComponent(".oases-cpa-deployment-lock/pid"))
        try write("not-a-pid\n", to: root.appendingPathComponent("cli-proxy-api.pid"))

        let result = try run(script: DeploymentControlService().scriptForVerification(
            action: .cancel,
            method: .native,
            installDirectory: root.path,
            controlToken: "preflight"
        ))
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(isAlive(process.processIdentifier))
        XCTAssertTrue(result.stderr.contains("PID"))
    }

    func testPauseResumeAndCancelMaintainStateAndTerminateDeploymentTree() throws {
        let root = try makeDirectory()
        let process = try startSleep()
        defer { stop(process) }
        writeManagedRoot(at: root)
        writeAttempt(at: root, token: "one-time", pid: process.processIdentifier)
        try write("\(process.processIdentifier)\n", to: root.appendingPathComponent(".oases-cpa-deployment-lock/pid"))

        let service = DeploymentControlService()
        let pause = try run(script: service.scriptForVerification(action: .pause, method: .native, installDirectory: root.path, controlToken: "one-time"))
        XCTAssertEqual(pause.status, 0, pause.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".oases-cpa-paused").path))
        XCTAssertEqual(processState(process.processIdentifier), "T")

        let resume = try run(script: service.scriptForVerification(action: .resume, method: .native, installDirectory: root.path, controlToken: "one-time"))
        XCTAssertEqual(resume.status, 0, resume.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".oases-cpa-paused").path))

        let cancel = try run(script: service.scriptForVerification(action: .cancel, method: .native, installDirectory: root.path, controlToken: "one-time"))
        XCTAssertEqual(cancel.status, 0, cancel.stderr)
        XCTAssertTrue(waitForExit(process))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".oases-cpa-installing").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".oases-cpa-deployment-lock").path))
        XCTAssertTrue((try? String(contentsOf: root.appendingPathComponent(".oases-cpa-failed"), encoding: .utf8))?.contains("reason=cancelled") == true)
    }

    func testCancelStopsOnlyVerifiedNativeProcesses() throws {
        let root = try makeDirectory()
        let installer = try startSleep()
        defer { stop(installer) }
        let process = try startManagedSleep(at: root.appendingPathComponent("cli-proxy-api/runtime/sleep"))
        defer { stop(process) }
        writeManagedRoot(at: root)
        writeAttempt(at: root, token: "native", pid: installer.processIdentifier)
        try write("\(installer.processIdentifier)\n", to: root.appendingPathComponent(".oases-cpa-deployment-lock/pid"))
        try write("\(process.processIdentifier)\n", to: root.appendingPathComponent("cli-proxy-api.pid"))

        let result = try run(script: DeploymentControlService().scriptForVerification(action: .cancel, method: .native, installDirectory: root.path, controlToken: "native"))
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(isAlive(process.processIdentifier))
    }

    func testDockerCancelUsesComposeDownAndWritesCancelledState() throws {
        let root = try makeDirectory()
        let installer = try startSleep()
        defer { stop(installer) }
        writeManagedRoot(at: root)
        writeAttempt(at: root, token: "docker", pid: installer.processIdentifier)
        try write("\(installer.processIdentifier)\n", to: root.appendingPathComponent(".oases-cpa-deployment-lock/pid"))
        try write("services:\n  cpa:\n    image: test\n", to: root.appendingPathComponent("compose.yaml"))
        let bin = try makeDirectory()
        let docker = bin.appendingPathComponent("docker")
        let argsFile = bin.appendingPathComponent("docker-args")
        try write("#!/bin/sh\nprintf '%s\\n' \"$*\" > \"\(argsFile.path)\"\n", to: docker)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docker.path)

        let result = try run(
            script: DeploymentControlService().scriptForVerification(action: .cancel, method: .docker, installDirectory: root.path, controlToken: "docker"),
            environment: ["PATH": "\(bin.path):/usr/bin:/bin"]
        )
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            (try? String(contentsOf: argsFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
            "compose down --volumes --remove-orphans",
            "stdout=\(result.stdout) stderr=\(result.stderr)"
        )
        XCTAssertTrue((try? String(contentsOf: root.appendingPathComponent(".oases-cpa-failed"), encoding: .utf8))?.contains("reason=cancelled") == true)
    }

    func testRemovalRejectsRootHomeUnmanagedAndSymlink() throws {
        let service = DeploymentRemovalService()
        let rootResult = try run(script: service.scriptForVerification(method: .native, installDirectory: "/"))
        XCTAssertNotEqual(rootResult.status, 0)
        let homeResult = try run(script: service.scriptForVerification(method: .native, installDirectory: NSHomeDirectory()))
        XCTAssertNotEqual(homeResult.status, 0)

        let unmanaged = try makeDirectory()
        try write("data", to: unmanaged.appendingPathComponent("keep.txt"))
        let unmanagedResult = try run(script: service.scriptForVerification(method: .native, installDirectory: unmanaged.path))
        XCTAssertNotEqual(unmanagedResult.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unmanaged.path))

        let managed = try makeDirectory()
        writeManagedRoot(at: managed)
        let link = temporaryRoot().appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: managed)
        let symlinkResult = try run(script: service.scriptForVerification(method: .native, installDirectory: link.path))
        XCTAssertNotEqual(symlinkResult.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: managed.path))
    }

    func testRemovalNativeStopsVerifiedProcessAndDeletesOnlyRoot() throws {
        let root = try makeDirectory()
        let sibling = root.deletingLastPathComponent().appendingPathComponent("sibling-(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sibling) }
        let process = try startManagedSleep(at: root.appendingPathComponent("cli-proxy-api/runtime/sleep"))
        defer { stop(process) }
        writeManagedRoot(at: root)
        try write("\(process.processIdentifier)\n", to: root.appendingPathComponent("cli-proxy-api.pid"))

        let result = try run(script: DeploymentRemovalService().scriptForVerification(method: .native, installDirectory: root.path))
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("OASES_CPA_REMOVED=1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
        XCTAssertTrue(waitForExit(process))
    }

    func testRemovalDockerUsesComposeDownAndDeletesRoot() throws {
        let root = try makeDirectory()
        writeManagedRoot(at: root)
        try write("services:\n  cpa:\n    image: test\n", to: root.appendingPathComponent("compose.yaml"))
        let bin = try makeDirectory()
        let docker = bin.appendingPathComponent("docker")
        let argsFile = bin.appendingPathComponent("docker-args")
        try write("#!/bin/sh\nprintf '%s\\n' \"$*\" > \"\(argsFile.path)\"\n", to: docker)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docker.path)

        let removalScript = DeploymentRemovalService().scriptForVerification(method: .docker, installDirectory: root.path)
        let result = try run(
            script: removalScript,
            environment: ["PATH": "\(bin.path):/usr/bin:/bin"]
        )
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("OASES_CPA_REMOVED=1"))
        XCTAssertEqual(
            (try? String(contentsOf: argsFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
            "compose down --volumes --remove-orphans",
            "stdout=\(result.stdout) stderr=\(result.stderr)"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    private struct ScriptResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func run(script: String, environment: [String: String] = [:]) throws -> ScriptResult {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-s"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        if !environment.isEmpty {
            var variables = ProcessInfo.processInfo.environment
            environment.forEach { variables[$0.key] = $0.value }
            process.environment = variables
        }
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        return ScriptResult(
            status: process.terminationStatus,
            stdout: String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private func startSleep() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "sleep 30 & wait"]
        try process.run()
        return process
    }

    private func startManagedSleep(at executable: URL) throws -> Process {
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        try process.run()
        return process
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGCONT)
        kill(process.processIdentifier, SIGTERM)
        process.waitUntilExit()
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return !process.isRunning
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private func processState(_ pid: pid_t) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "state="]
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oases-cpa-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryDirectories.append(root)
        return root
    }

    private func makeDirectory() throws -> URL {
        temporaryRoot()
    }

    private func writeManagedRoot(at root: URL) {
        try! write("owned-by=oases-cpa\n", to: root.appendingPathComponent(".oases-cpa-managed"))
    }

    private func writeAttempt(at root: URL, token: String, pid: pid_t) {
        try! write("timestamp=now\nmethod=native\nstage=prepare\npid=\(pid)\ncontrol_token=\(token)\n", to: root.appendingPathComponent(".oases-cpa-installing"))
        try! FileManager.default.createDirectory(at: root.appendingPathComponent(".oases-cpa-deployment-lock"), withIntermediateDirectories: true)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
