import Foundation
import Darwin
import XCTest
@testable import OasesCPA

final class SSHConnectionServiceSecurityTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testUnknownHostReturnsStructuredConfirmationWithoutWritingKnownHosts() throws {
        let knownHostsURL = try makeKnownHostsURL()
        let record = makeRecord(
            host: "[vps.example.com]:2222",
            key: "AAAAC3NzaC1lZDI1NTE5AAAAICi8lL3HgIbHPh6YxJ24nGPCSoVIfqhz0W2YAXziuKhK",
            fingerprint: "SHA256:EhasawLwWJGbfLKEzbrQKB4rV6gI/AybldVQ5mYd1RI"
        )

        let inspection = try SSHConnectionService.inspectHostKey(
            host: "vps.example.com",
            port: "2222",
            knownHostsURL: knownHostsURL,
            scanner: { _, _ in record }
        )

        guard case .needsConfirmation(let confirmation) = inspection else {
            return XCTFail("unknown host must require explicit confirmation")
        }
        XCTAssertEqual(confirmation.reason, .firstUse)
        XCTAssertEqual(confirmation.host, "vps.example.com")
        XCTAssertEqual(confirmation.port, 2222)
        XCTAssertEqual(confirmation.algorithm, "ssh-ed25519")
        XCTAssertEqual(confirmation.fingerprint, "SHA256:EhasawLwWJGbfLKEzbrQKB4rV6gI/AybldVQ5mYd1RI")
        XCTAssertFalse(FileManager.default.fileExists(atPath: knownHostsURL.path))
    }

    func testExplicitFirstUseConfirmationWrites0600KnownHostsAtomicallyAndBecomesTrusted() throws {
        let knownHostsURL = try makeKnownHostsURL()
        let record = makeRecord(
            host: "[vps.example.com]:2222",
            key: "AAAAC3NzaC1lZDI1NTE5AAAAICi8lL3HgIbHPh6YxJ24nGPCSoVIfqhz0W2YAXziuKhK",
            fingerprint: "SHA256:EhasawLwWJGbfLKEzbrQKB4rV6gI/AybldVQ5mYd1RI"
        )
        let inspection = try SSHConnectionService.inspectHostKey(
            host: "vps.example.com",
            port: "2222",
            knownHostsURL: knownHostsURL,
            scanner: { _, _ in record }
        )
        guard case .needsConfirmation(let confirmation) = inspection else {
            return XCTFail("unknown host must require explicit confirmation")
        }

        try SSHConnectionService.confirmHostKey(confirmation, knownHostsURL: knownHostsURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: knownHostsURL.path))
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: knownHostsURL.path)[.posixPermissions] as? NSNumber,
            NSNumber(value: 0o600)
        )
        XCTAssertEqual(
            try String(contentsOf: knownHostsURL, encoding: .utf8),
            "[vps.example.com]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICi8lL3HgIbHPh6YxJ24nGPCSoVIfqhz0W2YAXziuKhK\n"
        )

        let trusted = try SSHConnectionService.inspectHostKey(
            host: "vps.example.com",
            port: "2222",
            knownHostsURL: knownHostsURL,
            scanner: { _, _ in record }
        )
        XCTAssertEqual(trusted, .trusted)
    }

    func testConfirmationPreservesUnrelatedKnownHostsLinesAndComments() throws {
        let knownHostsURL = try makeKnownHostsURL()
        let unrelated = """
        # managed by another tool
        other.example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICi8lL3HgIbHPh6YxJ24nGPCSoVIfqhz0W2YAXziuKhK
        """
        try Data(unrelated.utf8).write(to: knownHostsURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHostsURL.path)
        let record = makeRecord(
            host: "[vps.example.com]:2222",
            key: "AAAAC3NzaC1lZDI1NTE5AAAAICi8lL3HgIbHPh6YxJ24nGPCSoVIfqhz0W2YAXziuKhK",
            fingerprint: "SHA256:EhasawLwWJGbfLKEzbrQKB4rV6gI/AybldVQ5mYd1RI"
        )
        let inspection = try SSHConnectionService.inspectHostKey(
            host: "vps.example.com",
            port: "2222",
            knownHostsURL: knownHostsURL,
            scanner: { _, _ in record }
        )
        guard case .needsConfirmation(let confirmation) = inspection else {
            return XCTFail("unrelated host entries must not satisfy first-use confirmation")
        }

        try SSHConnectionService.confirmHostKey(confirmation, knownHostsURL: knownHostsURL)

        let text = try String(contentsOf: knownHostsURL, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# managed by another tool\n"))
        XCTAssertTrue(text.contains("other.example.com ssh-ed25519"))
        XCTAssertTrue(text.contains("[vps.example.com]:2222 ssh-ed25519"))
    }

    func testChangedHostKeyIsNotTrustedAndLeavesExistingFileUntouchedUntilReplacementConfirmation() throws {
        let knownHostsURL = try makeKnownHostsURL()
        let oldLine = "[vps.example.com]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICi8lL3HgIbHPh6YxJ24nGPCSoVIfqhz0W2YAXziuKhK"
        try Data((oldLine + "\n").utf8).write(to: knownHostsURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHostsURL.path)
        let changed = makeRecord(
            host: "[vps.example.com]:2222",
            key: "AAAAC3NzaC1lZDI1NTE5AAAAIIC1jvjRKhNPqh8eaHfqO1U7Z25PwQK03QhK5GNfnafN",
            fingerprint: "SHA256:WHLyBFgaFLthRix5c7qzdRdol8RQfly2cFWg8TvFCKs"
        )

        let inspection = try SSHConnectionService.inspectHostKey(
            host: "vps.example.com",
            port: "2222",
            knownHostsURL: knownHostsURL,
            scanner: { _, _ in changed }
        )

        guard case .needsConfirmation(let confirmation) = inspection else {
            return XCTFail("changed host key must not be trusted")
        }
        XCTAssertEqual(confirmation.reason, .changed)
        XCTAssertEqual(confirmation.previousFingerprint, "SHA256:EhasawLwWJGbfLKEzbrQKB4rV6gI/AybldVQ5mYd1RI")
        XCTAssertEqual(try String(contentsOf: knownHostsURL, encoding: .utf8), oldLine + "\n")
    }

    func testChangedHostKeyConfirmationIsRejectedIfCurrentEntryChanged() throws {
        let knownHostsURL = try makeKnownHostsURL()
        let oldLine = "[vps.example.com]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICi8lL3HgIbHPh6YxJ24nGPCSoVIfqhz0W2YAXziuKhK"
        try Data((oldLine + "\n").utf8).write(to: knownHostsURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHostsURL.path)
        let changed = makeRecord(
            host: "[vps.example.com]:2222",
            key: "AAAAC3NzaC1lZDI1NTE5AAAAIIC1jvjRKhNPqh8eaHfqO1U7Z25PwQK03QhK5GNfnafN",
            fingerprint: "SHA256:WHLyBFgaFLthRix5c7qzdRdol8RQfly2cFWg8TvFCKs"
        )
        let inspection = try SSHConnectionService.inspectHostKey(
            host: "vps.example.com",
            port: "2222",
            knownHostsURL: knownHostsURL,
            scanner: { _, _ in changed }
        )
        guard case .needsConfirmation(let confirmation) = inspection else {
            return XCTFail("changed host key must require replacement confirmation")
        }

        try Data((
            "[vps.example.com]:2222 ssh-ed25519 " +
            "AAAAC3NzaC1lZDI1NTE5AAAAIAICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIC\n"
        ).utf8).write(to: knownHostsURL)

        XCTAssertThrowsError(
            try SSHConnectionService.confirmHostKey(confirmation, knownHostsURL: knownHostsURL)
        ) { error in
            XCTAssertEqual(error as? SSHConnectionError, .staleHostKeyConfirmation)
        }
        XCTAssertTrue(
            try String(contentsOf: knownHostsURL, encoding: .utf8)
                .contains("AAAAC3NzaC1lZDI1NTE5AAAAIAICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIC")
        )
    }

    func testChangedHostKeyIsReplacedOnlyAfterExplicitConfirmation() throws {
        let knownHostsURL = try makeKnownHostsURL()
        try Data("[vps.example.com]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICi8lL3HgIbHPh6YxJ24nGPCSoVIfqhz0W2YAXziuKhK\n".utf8)
            .write(to: knownHostsURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHostsURL.path)
        let changed = makeRecord(
            host: "[vps.example.com]:2222",
            key: "AAAAC3NzaC1lZDI1NTE5AAAAIIC1jvjRKhNPqh8eaHfqO1U7Z25PwQK03QhK5GNfnafN",
            fingerprint: "SHA256:WHLyBFgaFLthRix5c7qzdRdol8RQfly2cFWg8TvFCKs"
        )
        let inspection = try SSHConnectionService.inspectHostKey(
            host: "vps.example.com",
            port: "2222",
            knownHostsURL: knownHostsURL,
            scanner: { _, _ in changed }
        )
        guard case .needsConfirmation(let confirmation) = inspection else {
            return XCTFail("changed host key must require replacement confirmation")
        }

        try SSHConnectionService.confirmHostKey(confirmation, knownHostsURL: knownHostsURL)

        let text = try String(contentsOf: knownHostsURL, encoding: .utf8)
        XCTAssertFalse(text.contains("AAAAICi8lL3HgIbHPh6YxJ24nGPCSoVIfqhz0W2YAXziuKhK"))
        XCTAssertTrue(text.contains("AAAAIIC1jvjRKhNPqh8eaHfqO1U7Z25PwQK03QhK5GNfnafN"))
        XCTAssertEqual(
            try SSHConnectionService.inspectHostKey(
                host: "vps.example.com",
                port: "2222",
                knownHostsURL: knownHostsURL,
                scanner: { _, _ in changed }
            ),
            .trusted
        )
    }

    func testConcurrentConfirmationIsIdempotentAndLeavesOneTrustedEntry() throws {
        let knownHostsURL = try makeKnownHostsURL()
        let record = makeRecord(
            host: "[vps.example.com]:2222",
            key: "AAAAC3NzaC1lZDI1NTE5AAAAICi8lL3HgIbHPh6YxJ24nGPCSoVIfqhz0W2YAXziuKhK",
            fingerprint: "SHA256:EhasawLwWJGbfLKEzbrQKB4rV6gI/AybldVQ5mYd1RI"
        )
        let inspection = try SSHConnectionService.inspectHostKey(
            host: "vps.example.com",
            port: "2222",
            knownHostsURL: knownHostsURL,
            scanner: { _, _ in record }
        )
        guard case .needsConfirmation(let confirmation) = inspection else {
            return XCTFail("unknown host must require explicit confirmation")
        }

        let failures = NSLockBox()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            do {
                try SSHConnectionService.confirmHostKey(confirmation, knownHostsURL: knownHostsURL)
            } catch {
                failures.append(error)
            }
        }

        XCTAssertTrue(failures.errors.isEmpty, failures.errors.map(\.localizedDescription).joined(separator: "\n"))
        let lines = try String(contentsOf: knownHostsURL, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: knownHostsURL.path)[.posixPermissions] as? NSNumber,
            NSNumber(value: 0o600)
        )
    }

    func testHostPortUserAndPrivateKeyInputsRejectUnsafeValuesAndNeverUseAcceptNew() throws {
        let scanner: SSHHostKeyScanner = { _, _ in
            throw SSHConnectionError.hostKeyScanFailed("scanner must not run for invalid input")
        }

        XCTAssertThrowsError(try SSHConnectionService.inspectHostKey(
            host: "vps.example.com\n-evil",
            port: "22",
            scanner: scanner
        )) { error in
            XCTAssertEqual(error as? SSHConnectionError, .invalidHost)
        }
        XCTAssertThrowsError(try SSHConnectionService.inspectHostKey(
            host: "-oProxyCommand=unsafe",
            port: "22",
            scanner: scanner
        )) { error in
            XCTAssertEqual(error as? SSHConnectionError, .invalidHost)
        }
        XCTAssertThrowsError(try SSHConnectionService.inspectHostKey(
            host: "vps.example.com",
            port: "0",
            scanner: scanner
        )) { error in
            XCTAssertEqual(error as? SSHConnectionError, .invalidPort)
        }
        XCTAssertThrowsError(try SSHConnectionService.tunnelArguments(
            host: "vps.example.com",
            user: "root\nevil",
            port: "22",
            privateKeyPath: "/tmp/key"
        )) { error in
            XCTAssertEqual(error as? SSHConnectionError, .invalidUser)
        }
        XCTAssertThrowsError(try SSHConnectionService.tunnelArguments(
            host: "vps.example.com",
            user: "-oProxyCommand=unsafe",
            port: "22",
            privateKeyPath: "/tmp/key"
        )) { error in
            XCTAssertEqual(error as? SSHConnectionError, .invalidUser)
        }
        XCTAssertThrowsError(try SSHConnectionService.tunnelArguments(
            host: "vps.example.com",
            user: "root",
            port: "22",
            privateKeyPath: "/tmp/key\nevil"
        )) { error in
            XCTAssertEqual(error as? SSHConnectionError, .invalidPrivateKeyPath)
        }

        let arguments = try SSHConnectionService.connectionArguments(
            port: "22",
            privateKeyPath: "/tmp/key"
        )
        XCTAssertTrue(arguments.contains("StrictHostKeyChecking=yes"))
        XCTAssertFalse(arguments.contains("StrictHostKeyChecking=accept-new"))
    }

    func testKnownHostsRejectsSymlinkedParentDirectory() throws {
        let root = canonicalTemporaryDirectory
            .appendingPathComponent("oases-cpa-ssh-parent-symlink-\(UUID().uuidString)")
        let external = root.appendingPathComponent("external", isDirectory: true)
        let linkedParent = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: external)
        temporaryDirectories.append(root)

        let record = makeRecord(
            host: "[vps.example.com]:2222",
            key: "AAAAC3NzaC1lZDI1NTE5AAAAICi8lL3HgIbHPh6YxJ24nGPCSoVIfqhz0W2YAXziuKhK",
            fingerprint: "SHA256:EhasawLwWJGbfLKEzbrQKB4rV6gI/AybldVQ5mYd1RI"
        )

        XCTAssertThrowsError(
            try SSHConnectionService.inspectHostKey(
                host: "vps.example.com",
                port: "2222",
                knownHostsURL: linkedParent.appendingPathComponent("known_hosts"),
                scanner: { _, _ in record }
            )
        ) { error in
            guard case .cannotPrepareKnownHosts = error as? SSHConnectionError else {
                return XCTFail("symlinked known_hosts parent must fail closed: \(error)")
            }
        }
    }

    func testBracketedIPv6NonDefaultPortUsesCanonicalKnownHostsPattern() throws {
        let knownHostsURL = try makeKnownHostsURL()
        let record = makeRecord(
            host: "[2001:db8::1]:2222",
            key: "AAAAC3NzaC1lZDI1NTE5AAAAICi8lL3HgIbHPh6YxJ24nGPCSoVIfqhz0W2YAXziuKhK",
            fingerprint: "SHA256:EhasawLwWJGbfLKEzbrQKB4rV6gI/AybldVQ5mYd1RI"
        )

        let inspection = try SSHConnectionService.inspectHostKey(
            host: "[2001:db8::1]",
            port: "2222",
            knownHostsURL: knownHostsURL,
            scanner: { _, _ in record }
        )

        guard case .needsConfirmation(let confirmation) = inspection else {
            return XCTFail("bracketed IPv6 must produce a first-use confirmation")
        }
        XCTAssertEqual(confirmation.knownHostsLine, "[2001:db8::1]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICi8lL3HgIbHPh6YxJ24nGPCSoVIfqhz0W2YAXziuKhK")
    }

    func testExistingKnownHostsMatchesAnySupportedAlgorithmEntry() throws {
        let knownHostsURL = try makeKnownHostsURL()
        let key = "AAAAC3NzaC1lZDI1NTE5AAAAICi8lL3HgIbHPh6YxJ24nGPCSoVIfqhz0W2YAXziuKhK"
        try Data(("[vps.example.com]:2222 ssh-rsa \(key)\n" +
                  "[vps.example.com]:2222 ssh-ed25519 \(key)\n").utf8).write(to: knownHostsURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHostsURL.path)

        let inspection = try SSHConnectionService.inspectHostKey(
            host: "vps.example.com",
            port: "2222",
            knownHostsURL: knownHostsURL,
            scanner: { _, _ in
                SSHHostKeyRecord(
                    hostPattern: "[vps.example.com]:2222",
                    algorithm: "ssh-ed25519",
                    publicKey: key,
                    fingerprint: "SHA256:EhasawLwWJGbfLKEzbrQKB4rV6gI/AybldVQ5mYd1RI"
                )
            }
        )

        XCTAssertEqual(inspection, .trusted)
    }

    func testNewAlgorithmConfirmationAppendsAndRetainsOtherAlgorithm() throws {
        let knownHostsURL = try makeKnownHostsURL()
        let oldKey = "AAAAB3NzaC1yc2EAAAADAQABAAABAQCz3IVvOyeX2yTGMubsrhHu/cgYcu3UkDDdGYZxBh4T6zz/IxDrGPTYdRyQqhkxdERt1p+rsz6+kz/eC4LVlFEKBuUn1eNFDjEmgIEPgDLL8wCF5TbeUutZK8nlJeS1qzoZ0rGcrJABXZjD+oKYtE0VJ02Wv7Lhbrv2Ue6h02dl/jg6d5PilfvGbhlnzcRDb5BRcW5wKx3q8iTSFMU7DpsXGMff8Dwe5Ent00cDpBNheOlOBTIqDpxc+fA4Bf+L4kJQ/hfa6zhLJur2XDFfmPzw204+NlbwhgjGlNtOE9+aHF9o/eoB81TzqF66k52SZuwROSaiB9nO7M7ZdxKl5dAh"
        try Data(("[vps.example.com]:2222 ssh-rsa \(oldKey)\n").utf8).write(to: knownHostsURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHostsURL.path)
        let newEd25519 = makeRecord(
            host: "[vps.example.com]:2222",
            key: "AAAAC3NzaC1lZDI1NTE5AAAAIIC1jvjRKhNPqh8eaHfqO1U7Z25PwQK03QhK5GNfnafN",
            fingerprint: "SHA256:WHLyBFgaFLthRix5c7qzdRdol8RQfly2cFWg8TvFCKs"
        )

        let inspection = try SSHConnectionService.inspectHostKey(
            host: "vps.example.com",
            port: "2222",
            knownHostsURL: knownHostsURL,
            scanner: { _, _ in newEd25519 }
        )
        guard case .needsConfirmation(let confirmation) = inspection else {
            return XCTFail("new host-key algorithm must require explicit confirmation")
        }
        XCTAssertEqual(confirmation.reason, .changed)
        XCTAssertEqual(confirmation.algorithm, "ssh-ed25519")
        XCTAssertEqual(confirmation.previousFingerprint, "SHA256:0M0P6wcLjTg3LQ0LYgMGM/qq2/zil1/hNqmBnNZNpTk")

        try SSHConnectionService.confirmHostKey(confirmation, knownHostsURL: knownHostsURL)

        let text = try String(contentsOf: knownHostsURL, encoding: .utf8)
        XCTAssertTrue(text.contains("[vps.example.com]:2222 ssh-rsa \(oldKey)"))
        XCTAssertTrue(text.contains("[vps.example.com]:2222 ssh-ed25519 \(newEd25519.publicKey)"))
        XCTAssertEqual(
            try SSHConnectionService.inspectHostKey(
                host: "vps.example.com",
                port: "2222",
                knownHostsURL: knownHostsURL,
                scanner: { _, _ in newEd25519 }
            ),
            .trusted
        )
    }

    func testSSHToolRunnerBoundsOutputWhileDrainingBothPipes() throws {
        let result = try SSHConnectionService.runSSHToolForTesting(
            executable: "/bin/sh",
            arguments: ["-c", "head -c 400000 /dev/zero 1>&2; head -c 400000 /dev/zero"],
            timeout: 3
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.standardOutputTruncated)
        XCTAssertTrue(result.standardErrorTruncated)
        XCTAssertLessThanOrEqual(result.standardOutput.utf8.count, 256 * 1024)
        XCTAssertLessThanOrEqual(result.standardError.utf8.count, 256 * 1024)
    }

    func testSSHToolRunnerCanBeInjectedForScannerAndKeygenSeams() throws {
        let result = try SSHConnectionService.withSSHToolRunnerForTesting(
            { executable, arguments, standardInput, timeout in
                XCTAssertEqual(executable, "/usr/bin/ssh-keygen")
                XCTAssertEqual(arguments, ["-lf", "-", "-E", "sha256"])
                XCTAssertNotNil(standardInput)
                XCTAssertEqual(timeout, 10)
                return SSHProcessResult(
                    status: 0,
                    standardOutput: "256 SHA256:test comment (ED25519)\n",
                    standardError: "",
                    standardOutputTruncated: false,
                    standardErrorTruncated: false
                )
            },
            operation: {
                try SSHConnectionService.runSSHToolForTesting(
                    executable: "/usr/bin/ssh-keygen",
                    arguments: ["-lf", "-", "-E", "sha256"],
                    standardInput: "ssh-ed25519 AAAA\n"
                )
            }
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.standardOutput, "256 SHA256:test comment (ED25519)\n")
    }

    func testSSHToolRunnerKillsProcessGroupOnTimeout() throws {
        let startedAt = Date()
        XCTAssertThrowsError(
            try SSHConnectionService.runSSHToolForTesting(
                executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; sleep 10"],
                timeout: 0.1
            )
        ) { error in
            guard case .hostKeyScanFailed(let message) = error as? SSHConnectionError else {
                return XCTFail("timeout must use a safe SSH tool error: \(error)")
            }
            XCTAssertEqual(message, "SSH 工具执行超时")
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    func testSSHToolRunnerCancellationTerminatesProcessGroup() async throws {
        let startedAt = Date()
        let directory = canonicalTemporaryDirectory
            .appendingPathComponent("oases-cpa-ssh-runner-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        let pidMarker = directory.appendingPathComponent("pid")
        let task = Task {
            try SSHConnectionService.runSSHToolForTesting(
                executable: "/bin/sh",
                arguments: ["-c", "echo $$ > '\(pidMarker.path)'; sleep 10"],
                timeout: 10
            )
        }
        let markerDeadline = Date().addingTimeInterval(1)
        while !FileManager.default.fileExists(atPath: pidMarker.path), Date() < markerDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled SSH tool must not return success")
        } catch let error as SSHConnectionError {
            XCTAssertEqual(error, .hostKeyScanFailed("SSH 工具执行已取消"))
        }
        let pid = try XCTUnwrap(Int(String(contentsOf: pidMarker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(Darwin.kill(Int32(pid), 0), -1, "cancelled SSH process must be reaped")
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    @MainActor
    func testActiveDeploymentKeepsOriginalTargetAndPrivateKeySnapshot() throws {
        let store = DeploymentStore(autoProbe: false)
        let original = DeploymentExecutionRequest(
            target: .ssh,
            method: .native,
            host: "old.example.com",
            user: "root",
            port: "22",
            privateKeyPath: "/tmp/old-key",
            installDirectory: "/tmp/old-install"
        )
        store.beginOperationSnapshotForTesting(original)
        defer { store.endOperationSnapshotForTesting() }

        store.remoteHost = "new.example.com"
        store.privateKeyPath = "/tmp/new-key"

        let snapshot = try XCTUnwrap(store.operationRequestSnapshotForTesting)
        XCTAssertEqual(snapshot.host, "old.example.com")
        XCTAssertEqual(snapshot.privateKeyPath, "/tmp/old-key")
        XCTAssertEqual(store.remoteHost, "old.example.com")
        XCTAssertEqual(store.privateKeyPath, "/tmp/old-key")
    }

    func testKnownHostsLockIsSharedAcrossTwoProcesses() throws {
        let knownHostsURL = try makeKnownHostsURL()
        let markerURL = knownHostsURL.deletingLastPathComponent().appendingPathComponent("worker-ready")
        let executable = URL(fileURLWithPath: "/usr/bin/python3")
        let child = Process()
        child.executableURL = executable
        child.arguments = [
            "-c",
            "import fcntl, os, sys, time\nfd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)\nfcntl.lockf(fd, fcntl.LOCK_EX)\nopen(sys.argv[2], 'w').close()\ntime.sleep(0.6)",
            knownHostsURL.deletingLastPathComponent().appendingPathComponent(".known_hosts.lock").path,
            markerURL.path
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["OASES_CPA_KNOWN_HOSTS_LOCK_WORKER"] = "1"
        environment["OASES_CPA_KNOWN_HOSTS_LOCK_PATH"] = knownHostsURL.path
        environment["OASES_CPA_KNOWN_HOSTS_LOCK_MARKER"] = markerURL.path
        child.environment = environment
        let childOutput = Pipe()
        let childError = Pipe()
        child.standardOutput = childOutput
        child.standardError = childError
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
        }

        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: markerURL.path), Date() < deadline {
            usleep(10_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path), "worker did not acquire known_hosts lock")

        let record = makeRecord(
            host: "[vps.example.com]:2222",
            key: "AAAAC3NzaC1lZDI1NTE5AAAAICi8lL3HgIbHPh6YxJ24nGPCSoVIfqhz0W2YAXziuKhK",
            fingerprint: "SHA256:EhasawLwWJGbfLKEzbrQKB4rV6gI/AybldVQ5mYd1RI"
        )
        let startedAt = Date()
        _ = try SSHConnectionService.inspectHostKey(
            host: "vps.example.com",
            port: "2222",
            knownHostsURL: knownHostsURL,
            scanner: { _, _ in record }
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        child.waitUntilExit()
        let childDiagnostics = String(
            data: childOutput.fileHandleForReading.readDataToEndOfFile() + childError.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        if child.terminationStatus != 0, !childDiagnostics.isEmpty {
            XCTFail("lock worker failed: \(childDiagnostics.prefix(512))")
        }
        XCTAssertEqual(child.terminationStatus, 0)
        XCTAssertGreaterThanOrEqual(elapsed, 0.35, "known_hosts RMW lock was not shared across processes")
    }

    func testKnownHostsLockHolderWorker() throws {
        guard ProcessInfo.processInfo.environment["OASES_CPA_KNOWN_HOSTS_LOCK_WORKER"] == "1",
              let path = ProcessInfo.processInfo.environment["OASES_CPA_KNOWN_HOSTS_LOCK_PATH"],
              let marker = ProcessInfo.processInfo.environment["OASES_CPA_KNOWN_HOSTS_LOCK_MARKER"] else {
            return
        }
        try SSHConnectionService.holdKnownHostsLockForTesting(
            at: URL(fileURLWithPath: path),
            duration: 0.6,
            readyMarker: URL(fileURLWithPath: marker)
        )
    }

    private func makeKnownHostsURL() throws -> URL {
        let directory = canonicalTemporaryDirectory
            .appendingPathComponent("oases-cpa-ssh-security-\(UUID().uuidString)", isDirectory: true)
        XCTAssertTrue(directory.path.hasPrefix("/private/"), "test fixture must use canonical /private path: \(directory.path)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory.appendingPathComponent("known_hosts")
    }

    private var canonicalTemporaryDirectory: URL {
        let path = FileManager.default.temporaryDirectory.path
        return URL(fileURLWithPath: path.hasPrefix("/var/") ? "/private\(path)" : path)
    }

    private func makeRecord(host: String, key: String, fingerprint: String) -> SSHHostKeyRecord {
        SSHHostKeyRecord(
            hostPattern: host,
            algorithm: "ssh-ed25519",
            publicKey: key,
            fingerprint: fingerprint
        )
    }
}

private final class NSLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var errors: [Error] = []

    func append(_ error: Error) {
        lock.lock()
        errors.append(error)
        lock.unlock()
    }
}
